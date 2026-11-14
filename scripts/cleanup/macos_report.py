#!/usr/bin/env python3
"""Read-only macOS filesystem observations, coverage rendering and signed deltas."""
from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone

sys.dont_write_bytecode = True
from macos_ownership import absolute, command, metadata, read_metadata


def now():
    return datetime.now(timezone.utc).isoformat()


def integer(value):
    return value if type(value) is int and value >= 0 else None


def chronological(start, end):
    try:
        first, last = datetime.fromisoformat(start), datetime.fromisoformat(end)
        return first.utcoffset() is not None and last.utcoffset() is not None and first < last
    except (TypeError, ValueError):
        return False


class Filesystems:
    """Observe each device once per snapshot. Never sum APFS volume capacity."""
    def __init__(self, run=command, check=lambda: None, limit=16):
        self.run, self.check, self.limit = run, check, limit
        self.volumes, self.scopes = {}, []

    def observe(self, path, expected_device=None):
        path = absolute(path)
        scope = {"path": path, "status": "unknown", "filesystemId": None}
        self.scopes.append(scope)
        try:
            with metadata.root_scope(path, self.check) as pinned:
                device = os.fstat(pinned.descriptor).st_dev
                if expected_device is not None and device != expected_device:
                    raise metadata.BoundarySkipped("changed-skipped")
                key = str(device)
                scope["filesystemId"] = key
                if key not in self.volumes:
                    self.check()
                    if len(self.volumes) >= self.limit:
                        scope["status"] = "filesystem-limit"
                        scope["filesystemId"] = None
                        return None
                    self.volumes[key] = self.sample(pinned, device)
                scope["status"] = self.volumes[key]["status"]
                return key
        except metadata.BudgetExceeded as error:
            scope["status"] = str(error)
        except metadata.BoundarySkipped as error:
            scope["status"] = error.status
        except FileNotFoundError:
            scope["status"] = "absent"
        except OSError:
            scope["status"] = "inaccessible"
        return None

    def sample(self, pinned, device):
        result = {"filesystemId": str(device), "deviceNumber": device, "status": "unknown",
                  "observedAt": now(), "anchor": pinned.path, "method": "fstatvfs-pinned-directory",
                  "totalBytes": None, "availableBytes": None, "freeBytes": None,
                  "volumeUuid": None, "deviceNode": None, "mountPoint": None,
                  "filesystemType": None, "apfsContainer": None, "volumeGroup": None,
                  "containerCapacityBytes": None, "containerFreeBytes": None,
                  "sharing": "unknown", "identityStatus": "unknown", "failures": []}
        try:
            values = os.fstatvfs(pinned.descriptor)
            unit = values.f_frsize or values.f_bsize
            if unit <= 0 or min(values.f_blocks, values.f_bfree, values.f_bavail) < 0:
                raise ValueError("invalid-space-observation")
            result.update(totalBytes=values.f_blocks * unit, freeBytes=values.f_bfree * unit,
                          availableBytes=values.f_bavail * unit, status="observed")
        except (OSError, ValueError):
            result["failures"].append("space-unavailable")
        try:
            # df discovers a device, never the byte measurement. Validate its rdev
            # against the pinned directory before asking diskutil about that device.
            self.check()
            code, text = self.run(["/bin/df", "-Pk", pinned.path], seconds=3,
                                  env={**os.environ, "LC_ALL": "C"})
            lines = text.splitlines()
            node = lines[-1].split()[0] if lines else ""
            if code or not re.fullmatch(r"/dev/disk\d+(?:s\d+)*", node):
                raise ValueError("device-unresolved")
            info = os.stat(node, follow_symlinks=False)
            if not stat.S_ISBLK(info.st_mode) or info.st_rdev != device:
                raise ValueError("device-mismatch")
            self.check()
            code, text = self.run(["/usr/sbin/diskutil", "info", "-plist", node], seconds=3)
            data = plistlib.loads(text.encode()) if not code else None
            if not isinstance(data, dict) or data.get("DeviceNode") != node:
                raise ValueError("device-metadata-mismatch")
            # Do not retain disk names, raw plists, or arbitrary diagnostic text.
            result["deviceNode"] = node
            for source, target in (("VolumeUUID", "volumeUuid"), ("APFSVolumeGroupID", "volumeGroup")):
                value = data.get(source)
                if isinstance(value, str) and re.fullmatch(r"[0-9A-Fa-f-]{36}", value):
                    result[target] = value.upper()
            mount = data.get("MountPoint")
            if isinstance(mount, str) and mount.startswith("/"):
                result["mountPoint"] = mount
            kind = data.get("FilesystemType")
            result["filesystemType"] = kind if isinstance(kind, str) and re.fullmatch(r"[a-zA-Z0-9_-]{1,32}", kind) else None
            container = data.get("APFSContainerReference")
            if result["filesystemType"] == "apfs" and isinstance(container, str) and re.fullmatch(r"disk\d+", container):
                result.update(apfsContainer=container, sharing="apfs-shared-container",
                              containerCapacityBytes=integer(data.get("APFSContainerSize")),
                              containerFreeBytes=integer(data.get("APFSContainerFree")))
            result["identityStatus"] = "verified-device" if result["volumeUuid"] else "device-only"
        except metadata.BudgetExceeded as error:
            result["failures"].append(str(error))
        except (OSError, ValueError, IndexError, TimeoutError, subprocess.SubprocessError):
            result["failures"].append("filesystem-identity-unavailable")
        return result

    def evidence(self):
        groups = {}
        for volume in self.volumes.values():
            if volume["apfsContainer"]:
                groups.setdefault(volume["apfsContainer"], []).append(volume["filesystemId"])
        return {"method": "per-filesystem-observations-no-capacity-sum", "maxFilesystems": self.limit,
                "filesystems": list(self.volumes.values()), "scopes": self.scopes,
                "sharedContainers": [{"container": key, "filesystemIds": values}
                                     for key, values in sorted(groups.items())],
                "limitations": ["APFS volume capacity/free space is shared, non-additive and may be quota/reserve constrained.",
                                "Container and filesystem readings are sequential observations, not an atomic snapshot.",
                                "Clone/snapshot/purgeable sharing and uniquely reclaimable bytes remain unknown."]}


def coverage_summary(records):
    counts, skips = {}, {"linkedSkipped": 0, "inaccessibleSkipped": 0, "depthSkipped": 0,
                        "prunedDirectories": 0, "crossFilesystemSkipped": 0}
    for record in records:
        status = record["status"]
        counts[status] = counts.get(status, 0) + 1
        for name in skips:
            skips[name] += record.get(name, 0)
    return {"statusCounts": counts, "skipCounts": skips,
            "scope": "bounded-discovery-and-target-walks-not-full-drive"}


def net_changes(before, after):
    """Return per-volume signed available-byte changes; never a shared-space sum."""
    def identities(evidence):
        found = {}
        for volume in evidence.get("filesystems", []):
            identity = volume.get("volumeUuid")
            if identity:
                found.setdefault(identity, []).append(volume)
        return found
    old, new = identities(before), identities(after)
    changes = []
    for identity in sorted(old.keys() | new.keys()):
        pair = old.get(identity, []) + new.get(identity, [])
        valid = len(old.get(identity, [])) == len(new.get(identity, [])) == 1
        start, end = (old[identity][0], new[identity][0]) if valid else ({}, {})
        valid = (valid and start.get("identityStatus") == end.get("identityStatus") == "verified-device"
                 and start.get("status") == end.get("status") == "observed"
                 and start.get("apfsContainer") == end.get("apfsContainer")
                 and start.get("method") == end.get("method") == "fstatvfs-pinned-directory"
                 and integer(start.get("availableBytes")) is not None
                 and integer(end.get("availableBytes")) is not None
                 and chronological(start.get("observedAt"), end.get("observedAt")))
        changes.append({"volumeUuid": identity, "apfsContainer": pair[0].get("apfsContainer"),
                        "beforeAt": start.get("observedAt"), "afterAt": end.get("observedAt"),
                        "observedNetChangeBytes": end["availableBytes"] - start["availableBytes"] if valid else None,
                        "status": "observed" if valid else "unknown-unmatched-or-incomplete"})
    unknown = sum(not volume.get("volumeUuid") for evidence in (before, after)
                  for volume in evidence.get("filesystems", []))
    return {"changes": changes, "unidentifiedObservations": unknown,
            "attribution": "Observed interval change only; no causal attribution or uniquely recovered-byte claim.",
            "aggregation": "Do not sum changes across volumes sharing an APFS container."}


def size(value, signed=False):
    if value is None:
        return "unknown"
    return f"{value / (1024 ** 2):{'+.2f' if signed else '.2f'}} MiB ({value} bytes)"


def safe(value):
    # Evidence can contain literal tabs/newlines/Markdown in filenames.
    return json.dumps(str(value), ensure_ascii=True)[1:-1].replace("|", "\\|").replace("`", "\\u0060")


def render(report, before=None):
    purpose = report.get("purpose")
    if purpose not in ("read-only-macos-discovery", "read-only-macos-space-snapshot"):
        raise ValueError("not-macos-evidence")
    space = report.get("filesystemSpace", {})
    lines = ["# macOS read-only evidence", "", "Not a cleanup plan. Unique recovery: unknown.", "",
             "## Filesystem space (non-additive)"]
    for volume in space.get("filesystems", []):
        lines.append(f"- Filesystem {safe(volume['filesystemId'])}: {safe(volume.get('deviceNode'))}; "
                     f"mount {safe(volume.get('mountPoint'))}; available {size(volume.get('availableBytes'))}; "
                     f"capacity {size(volume.get('totalBytes'))}; identity {safe(volume.get('identityStatus'))}; "
                     f"method {safe(volume.get('method'))}; observed {safe(volume.get('observedAt'))}.")
        if volume.get("apfsContainer"):
            lines.append(f"  Shared APFS container {safe(volume['apfsContainer'])}: "
                         f"capacity {size(volume.get('containerCapacityBytes'))}; "
                         f"free {size(volume.get('containerFreeBytes'))}. Do not add volume capacities/free space.")
        if volume.get("failures"):
            lines.append("  Gaps: " + safe(", ".join(volume["failures"])))
    for scope in space.get("scopes", []):
        lines.append(f"- Space scope {safe(scope['path'])}: filesystem {safe(scope['filesystemId'])}; "
                     f"{safe(scope['status'])}" + (" (unknown, not zero)." if scope["status"] != "observed" else "."))
    lines.extend("- " + text for text in space.get("limitations", []))
    if purpose == "read-only-macos-discovery":
        lines.extend(["", "## Coverage", "Bounded scopes, not a full-drive census.",
                      "Limits: " + safe(json.dumps(report["limits"], sort_keys=True)),
                      "Status counts: " + safe(json.dumps(report["coverageSummary"]["statusCounts"], sort_keys=True)),
                      "Skip counts: " + safe(json.dumps(report["coverageSummary"]["skipCounts"], sort_keys=True)),
                      "Workspace descent exclusions: " + safe(", ".join(report["workspaceDescentExclusions"])),
                      f"Top-N omitted matches: {report['omittedMatches']}; below-threshold complete targets: {report['belowThresholdTargets']}."])
        for stage in report["discoveryStages"]:
            lines.append(f"- Stage {stage['name']}: {stage['status']}")
        for scope in report["coverage"]:
            if scope["status"] not in ("complete", "complete-discovery", "absent") or any(
                    scope.get(key, 0) for key in report["coverageSummary"]["skipCounts"]):
                lines.append(f"- {safe(scope['path'])}: {safe(scope['status'])}; " + safe(json.dumps(
                    {key: value for key, value in scope.items() if key not in ("path", "status")}, sort_keys=True)))
        lines.extend(["", "## Findings (non-selectable)", "Logical/allocation subtotals are observations, not unique recovery; do not sum item rows."])
        for item in report["items"]:
            lines.append(f"- {safe(item['path'])}: {item['classification']}; coverage {item['coverage']}; "
                         f"filesystem {safe(item.get('filesystemId'))}; logical {size(item['logicalBytes'])}; "
                         f"allocated {size(item['allocatedBytes'])}; unique recovery unknown. "
                         f"Method {safe(item['allocationMethod'])}; hardlinked identities {item['sharedFiles']}; "
                         f"unknown allocation files {item['unknownAllocationFiles']}; clone/snapshot sharing unknown. "
                         f"Observed partial subtotals: logical {size(item['observedLogicalBytes'])}, "
                         f"known allocation {size(item['observedAllocatedKnownBytes'])}.")
        totals = report["totals"]
        lines.append(f"Identity-deduplicated observed subtotals (including omitted rows): logical {size(totals['observedLogicalBytes'])}; "
                     f"known allocation {size(totals['observedAllocatedKnownBytes'])}; unknown allocation files {totals['unknownAllocationFiles']}.")
        for key in ("processCensus", "registeredMcp"):
            lines.append(f"{key}: {safe(json.dumps(report[key], sort_keys=True))}")
        lines.extend("- " + safe(text) for text in report.get("warnings", []) + report.get("limitations", []))
    if before is not None:
        delta = net_changes(before.get("filesystemSpace", {}), space)
        lines.extend(["", "## Observed net available-space change", delta["attribution"], delta["aggregation"]])
        for change in delta["changes"]:
            lines.append(f"- {change['volumeUuid']}: {size(change['observedNetChangeBytes'], signed=True)}; "
                         f"{change['status']}; {safe(change['beforeAt'])} to {safe(change['afterAt'])}.")
        lines.append(f"Unidentified observations: {delta['unidentifiedObservations']} (change unknown).")
    return "\n".join(lines) + "\n"


def write_private(destination, result):
    destination = absolute(destination)
    with metadata.root_scope(os.path.dirname(destination)) as parent:
        fd = os.open(os.path.basename(destination), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent.descriptor)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
            handle.write("\n")


def load(path):
    data = json.loads(read_metadata(absolute(path), limit=16 * 1024 * 1024))
    if data.get("purpose") not in ("read-only-macos-discovery", "read-only-macos-space-snapshot"):
        raise ValueError("not-macos-evidence")
    return data


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    snapshot = modes.add_parser("snapshot", help="Read-only space snapshot of exact existing retained directories")
    snapshot.add_argument("--path", action="append", required=True)
    snapshot.add_argument("--output", required=True)
    report = modes.add_parser("render", help="Render saved evidence without rescanning")
    report.add_argument("--input", required=True)
    report.add_argument("--before", help="Saved immediately-pre-operation evidence for a signed interval comparison")
    args = parser.parse_args(argv)
    if args.mode == "render":
        current, before = load(args.input), load(args.before) if args.before else None
        if before is not None and (before["purpose"] != "read-only-macos-space-snapshot" or
                                   current["purpose"] != "read-only-macos-space-snapshot"):
            parser.error("Interval comparisons require fresh space snapshots, not a discovery scan baseline")
        print(render(current, before), end="")
        return
    if platform.system() != "Darwin":
        parser.error("Space snapshots require macOS")
    if len(args.path) > 32:
        parser.error("At most 32 exact paths per snapshot")
    import time
    deadline = time.monotonic() + 15
    def check():
        if time.monotonic() >= deadline:
            raise metadata.BudgetExceeded("timed-out")
    def run(arguments, seconds=3, **kwargs):
        check()
        return command(arguments, seconds=min(seconds, max(0.01, deadline - time.monotonic())), **kwargs)
    evidence = Filesystems(run, check)
    for path in args.path:
        evidence.observe(path)
    result = {"schemaVersion": "1.0", "purpose": "read-only-macos-space-snapshot",
              "createdAt": now(), "filesystemSpace": evidence.evidence()}
    write_private(args.output, result)
    print(json.dumps({"purpose": result["purpose"], "filesystems": len(evidence.volumes)}))


if __name__ == "__main__":
    main()
