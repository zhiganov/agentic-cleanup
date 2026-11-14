#!/usr/bin/env python3
"""Focused read-only accounting fixtures; no cleanup or dependency installation."""
import copy
import json
import os
import plistlib
import stat
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_report as report
import macos_scan as scan
from macos_ownership import no_processes

UUIDS = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222",
         "33333333-3333-3333-3333-333333333333"]


class SpaceAccounting(unittest.TestCase):
    def collector(self, broken=None, limit=16):
        paths = {"/": 1, "/System/Volumes/Data": 2, "/Users/fixture": 2, "/Volumes/External": 3}
        nodes = {1: "/dev/disk3s1s1", 2: "/dev/disk3s5", 3: "/dev/disk4s1"}
        calls = []
        @contextmanager
        def scope(path, check=lambda: None):
            check()
            if path == "/denied":
                raise PermissionError("fixture")
            if path == "/linked":
                raise report.metadata.BoundarySkipped("linked-skipped")
            if path not in paths:
                raise FileNotFoundError("fixture")
            yield SimpleNamespace(path=path, descriptor=paths[path])
        def run(args, **kwargs):
            calls.append(args)
            if broken == "timeout":
                raise TimeoutError("sensitive-fixture-never-printed")
            if args[0] == "/bin/df":
                if broken == "df-exit":
                    return 7, "sensitive-fixture-never-printed"
                if broken == "df-malformed":
                    return 0, "sensitive-fixture-never-printed"
                if broken == "first-command-failed" and len(calls) == 1:
                    return 7, "sensitive-fixture-never-printed"
                return 0, "Filesystem 1024-blocks Used Available Capacity Mounted on\n" + nodes[paths[args[-1]]] + " 999 1 2 1% /mount with spaces\n"
            device = next(key for key, node in nodes.items() if node == args[-1])
            data = {"DeviceNode": args[-1], "VolumeUUID": UUIDS[device - 1],
                    "FilesystemType": "apfs", "MountPoint": list(paths)[device - 1],
                    "VolumeName": "sensitive-fixture-never-printed"}
            if device in (1, 2):
                data.update(APFSContainerReference="disk3", APFSContainerSize=1000000,
                            APFSContainerFree=200000, APFSVolumeGroupID=UUIDS[0])
            else:
                data.update(APFSContainerReference="disk4", APFSContainerSize=3000000,
                            APFSContainerFree=1500000)
            if broken == "metadata-device":
                data["DeviceNode"] = "/dev/disk99"
            if broken == "metadata-exit":
                return 8, "sensitive-fixture-never-printed"
            if broken == "missing-uuid":
                data.pop("VolumeUUID")
            if broken == "invalid-uuid":
                data["VolumeUUID"] = "-" * 36
            if broken == "native-error":
                raise PermissionError(13, "sensitive-fixture-never-printed")
            return (0, "not a plist") if broken == "malformed" else (0, plistlib.dumps(data).decode())
        original_stat = os.stat
        def device_stat(node, *args, **kwargs):
            if node not in nodes.values():
                return original_stat(node, *args, **kwargs)
            return SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=99 if broken == "rdev" else
                                   next(key for key, value in nodes.items() if value == node))
        def statvfs(fd):
            if broken == "allocation-api":
                raise OSError("fixture")
            values = SimpleNamespace(f_fsid=fd, f_frsize=4096, f_bsize=4096, f_blocks=100,
                                     f_bfree=30, f_bavail=20 if fd != 3 else 50)
            if broken == "missing-fsid" or broken == "first-missing-fsid" and fd == 1:
                del values.f_fsid
            return values
        self.addCleanup(patch.stopall)
        patch.object(report.metadata, "root_scope", scope).start()
        patch("os.fstat", side_effect=lambda fd: SimpleNamespace(
            st_dev=2 if broken in ("shared-inode-device", "first-command-failed", "first-missing-fsid")
            and fd in (1, 2) else fd)).start()
        patch("os.fstatvfs", side_effect=statvfs).start()
        patch("os.stat", side_effect=device_stat).start()
        return report.Filesystems(run=run, limit=limit), calls

    def test_system_data_with_same_inode_device_keep_distinct_mounted_filesystems(self):
        collector, calls = self.collector("shared-inode-device")
        collector.observe("/", expected_device=2)
        collector.observe("/System/Volumes/Data", expected_device=2)
        data = collector.evidence()
        self.assertEqual(len(data["filesystems"]), 2)
        self.assertEqual([row["filesystemId"] for row in data["filesystems"]], ["1", "2"])
        self.assertTrue(all(row["identityStatus"] == "verified-device" for row in data["filesystems"]))
        self.assertNotEqual(data["filesystems"][0]["volumeUuid"], data["filesystems"][1]["volumeUuid"])
        self.assertEqual(data["sharedContainers"][0]["filesystemIds"], ["1", "2"])
        self.assertEqual(len(calls), 4)

    def test_failed_first_lookup_never_promotes_unknown_identity_or_poisons_data(self):
        collector, calls = self.collector("first-command-failed")
        first = collector.observe("/")
        collector.observe("/")  # same actual filesystem: preserve gap, no retry
        data = collector.observe("/System/Volumes/Data")
        self.assertNotEqual(first, data)
        self.assertEqual(collector.volumes[first]["identityStatus"], "unknown")
        self.assertEqual(collector.volumes[data]["identityStatus"], "verified-device")
        self.assertEqual(collector.scopes[1]["identityStatus"], "unknown")
        self.assertEqual(len(calls), 3)
        delta = report.net_changes(collector.evidence(), collector.evidence())
        self.assertTrue(all(row["observedNetChangeBytes"] is None for row in delta["changes"]))

    def test_missing_first_filesystem_id_is_isolated_not_cached_by_inode_device(self):
        collector, calls = self.collector("first-missing-fsid")
        first = collector.observe("/")
        second = collector.observe("/System/Volumes/Data")
        self.assertTrue(first.startswith("unknown-"))
        self.assertEqual(second, "2")
        self.assertIsNone(collector.volumes[first]["deviceNumber"])
        self.assertIsNone(collector.volumes[first]["volumeUuid"])
        self.assertEqual(collector.volumes[second]["identityStatus"], "verified-device")
        self.assertEqual(len(calls), 2)

    def test_stage_diagnostics_are_safe_and_specific(self):
        cases = {"df-exit": ("device-discovery", "command-failed"),
                 "df-malformed": ("device-discovery", "unsupported-device-output"),
                 "rdev": ("device-verification", "block-device-fsid-mismatch"),
                 "metadata-exit": ("device-metadata", "command-failed"),
                 "malformed": ("plist-parsing", "malformed-output"),
                 "metadata-device": ("identity-fields", "device-node-mismatch-or-missing"),
                 "missing-uuid": ("identity-fields", "volume-uuid-missing-or-invalid"),
                 "invalid-uuid": ("identity-fields", "volume-uuid-missing-or-invalid"),
                 "native-error": ("device-metadata", "native-error"),
                 "timeout": ("device-discovery", "command-timeout"),
                 "missing-fsid": ("filesystem-id", "missing-or-invalid-fsid")}
        for failure, (stage, code) in cases.items():
            with self.subTest(failure=failure):
                collector, calls = self.collector(failure)
                collector.observe("/")
                data = collector.evidence()
                item = data["filesystems"][0]
                self.assertIn({"stage": stage, "code": code},
                              [{key: row[key] for key in ("stage", "code")} for row in item["diagnostics"]])
                self.assertNotEqual(item["identityStatus"], "verified-device")
                text = report.render({"purpose": "read-only-macos-space-snapshot", "filesystemSpace": data})
                self.assertIn(stage, text)
                self.assertIn(code, text)
                self.assertNotIn("sensitive-fixture", text)
                self.assertNotIn("sensitive-fixture", json.dumps(data))
                for row in item["diagnostics"]:
                    self.assertLessEqual(set(row), {"stage", "code", "exitCode", "errno"})
                if failure == "native-error":
                    self.assertEqual(item["diagnostics"][0]["errno"], 13)
                self.assertLessEqual(len(calls), 2)
                patch.stopall()

    def test_system_data_share_capacity_external_is_separate_no_aggregate(self):
        collector, calls = self.collector()
        for path in ("/", "/System/Volumes/Data", "/Users/fixture", "/Volumes/External"):
            collector.observe(path)
        data = collector.evidence()
        self.assertEqual(len(data["filesystems"]), 3)
        self.assertEqual(len(calls), 6)  # one df/diskutil pair per device, not path
        groups = {row["container"]: row["filesystemIds"] for row in data["sharedContainers"]}
        self.assertEqual(groups, {"disk3": ["1", "2"], "disk4": ["3"]})
        self.assertNotIn("totalBytes", data)
        self.assertNotIn("availableBytes", data)
        self.assertEqual(data["scopes"][2]["filesystemId"], "2")
        self.assertEqual(data["filesystems"][1]["availableBytes"], 20 * 4096)
        self.assertNotIn("sensitive-fixture", json.dumps(data))

    def test_failure_modes_keep_identity_unknown_without_losing_observed_bytes(self):
        for failure in ("rdev", "metadata-device", "malformed", "timeout"):
            with self.subTest(failure=failure):
                collector, calls = self.collector(failure)
                collector.observe("/")
                item = collector.evidence()["filesystems"][0]
                self.assertEqual(item["status"], "observed")
                self.assertEqual(item["availableBytes"], 20 * 4096)
                self.assertEqual(item["identityStatus"], "unknown")
                self.assertIsNone(item["volumeUuid"])
                self.assertNotIn("sensitive-fixture", json.dumps(item))
                self.assertLessEqual(len(calls), 2)  # no fallback/retry
                patch.stopall()

    def test_space_api_failure_unknown_not_zero(self):
        collector, _ = self.collector("allocation-api")
        collector.observe("/")
        item = collector.evidence()["filesystems"][0]
        self.assertIsNone(item["availableBytes"])
        self.assertIsNone(item["totalBytes"])
        self.assertEqual(item["status"], "unknown")
        self.assertIn("space-unavailable", item["failures"])

    def test_missing_denied_links_and_changed_device_do_not_fall_back_to_root(self):
        collector, calls = self.collector()
        for path in ("/missing", "/denied", "/linked"):
            self.assertIsNone(collector.observe(path))
        self.assertIsNone(collector.observe("/", expected_device=999))
        self.assertEqual(calls, [])
        self.assertEqual([scope["status"] for scope in collector.scopes],
                         ["absent", "inaccessible", "linked-skipped", "changed-skipped"])

    def test_filesystem_budget_and_time_budget_are_explicit(self):
        collector, calls = self.collector(limit=1)
        collector.observe("/")
        collector.observe("/Volumes/External")
        self.assertEqual(collector.scopes[-1]["status"], "filesystem-limit")
        self.assertEqual(len(calls), 2)
        def timeout():
            raise report.metadata.BudgetExceeded("timed-out")
        collector.check = timeout
        self.assertIsNone(collector.observe("/Users/fixture"))
        self.assertEqual(collector.scopes[-1]["status"], "timed-out")

    def test_signed_negative_change_despite_independent_successful_operation(self):
        collector, _ = self.collector()
        collector.observe("/")
        before = collector.evidence()
        before["filesystems"][0]["observedAt"] = "2026-01-01T01:00:00+00:00"
        after = copy.deepcopy(before)
        after["filesystems"][0].update(availableBytes=100, observedAt="2026-01-01T01:00:01+00:00")
        operation = {"status": "completed", "selectedScopeDecreaseBytes": 4000}
        delta = report.net_changes(before, after)
        self.assertEqual(operation["status"], "completed")
        self.assertEqual(delta["changes"][0]["observedNetChangeBytes"], 100 - 20 * 4096)
        self.assertIn("no causal attribution", delta["attribution"])
        self.assertNotIn("total", delta)
        rendered = report.render({"purpose": "read-only-macos-space-snapshot", "filesystemSpace": after},
                                 {"filesystemSpace": before})
        self.assertIn("-0.08 MiB", rendered)
        self.assertIn("Do not sum", rendered)

    def test_unmatched_duplicate_reverse_unknown_or_changed_pairs_stay_unknown(self):
        collector, _ = self.collector()
        collector.observe("/")
        before = collector.evidence()
        before["filesystems"][0]["observedAt"] = "2026-01-01T01:00:00+00:00"
        for mutation in ("missing", "uuid", "duplicate", "reverse", "available", "method", "identity", "container", "invalid-time"):
            with self.subTest(mutation=mutation):
                after = copy.deepcopy(before)
                row = after["filesystems"][0]
                row["observedAt"] = "2026-01-01T01:00:01+00:00"
                if mutation == "missing":
                    after["filesystems"] = []
                elif mutation == "uuid":
                    row["volumeUuid"] = UUIDS[2]
                elif mutation == "duplicate":
                    after["filesystems"].append(copy.deepcopy(row))
                elif mutation == "reverse":
                    row["observedAt"] = "2025-01-01T01:00:00+00:00"
                elif mutation == "available":
                    row["availableBytes"] = None
                elif mutation == "method":
                    row["method"] = "other"
                elif mutation == "identity":
                    row["identityStatus"] = "unknown"
                elif mutation == "container":
                    row["apfsContainer"] = "disk99"
                else:
                    row["observedAt"] = "not-a-date"
                changes = report.net_changes(before, after)["changes"]
                self.assertTrue(changes)
                self.assertTrue(all(change["observedNetChangeBytes"] is None for change in changes))
        before["filesystems"][0]["volumeUuid"] = None
        self.assertEqual(report.net_changes(before, before)["unidentifiedObservations"], 2)


@unittest.skipUnless(os.name == "posix", "POSIX metadata fixtures")
class ScanAccounting(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cleanup-accounting-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home, self.work = self.root / "home", self.root / "work"
        self.home.mkdir()
        (self.work / ".opencode").mkdir(parents=True)

    def scanner(self, **kwargs):
        return scan.Scanner(self.home, self.work, env={}, application_roots=[], process=no_processes(),
                            system_config=str(self.root / "managed"), tool_probe=False, space_probe=False,
                            minimum_bytes=1, **kwargs)

    def file(self, relative, data=b"1234567"):
        target = self.home / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return target

    def test_partial_unknown_allocation_and_renderer_coverage_are_not_zero(self):
        cache = self.file("Library/Caches/fixture/a.bin").parent
        (cache / "linked").symlink_to(self.work)
        with patch.object(scan.metadata, "allocated_bytes", return_value=(None, "unsupported")):
            data = self.scanner().scan()
        item = next(row for row in data["items"] if row["path"] == str(cache))
        self.assertIsNone(item["logicalBytes"])
        self.assertIsNone(item["allocatedBytes"])
        self.assertEqual(item["unknownAllocationFiles"], 1)
        self.assertEqual(item["observedLogicalBytes"], 7)
        self.assertGreater(data["coverageSummary"]["skipCounts"]["linkedSkipped"], 0)
        text = report.render(data)
        self.assertIn("allocated unknown", text)
        self.assertIn("linkedSkipped", text)
        self.assertIn("Unique recovery: unknown", text)

    def test_hardlinks_deduplicate_global_but_distinct_clone_identities_do_not_prove_recovery(self):
        source = self.file("Library/Caches/one/a.bin")
        dest = self.home / "Library/Caches/two/b.bin"
        dest.parent.mkdir(parents=True)
        os.link(source, dest)
        # Distinct inode with identical allocation simulates clone metadata: the
        # scanner cannot determine extent sharing and must not estimate recovery.
        self.file("Library/Caches/three/clone.bin")
        data = self.scanner().scan()
        self.assertEqual(data["totals"]["observedLogicalBytes"], 14)
        items = [row for row in data["items"] if row["category"] == "app-cache"]
        self.assertEqual(sum(row["logicalBytes"] for row in items), 21)
        self.assertTrue(all(row["estimatedReclaimableBytes"] is None for row in items))
        self.assertTrue(all(row["cloneSnapshotSharing"] == "unknown" for row in items))
        self.assertIn("do not sum item rows", report.render(data))

    def test_top_n_pruning_depth_and_uninspected_stages_are_reported(self):
        for index in range(3):
            self.file(f"Library/Caches/{index}/nested/deeper/data.bin")
        (self.work / "node_modules").mkdir()
        data = self.scanner(limit=1, max_depth=1).scan()
        self.assertGreaterEqual(data["omittedMatches"], 2)
        self.assertGreater(data["coverageSummary"]["skipCounts"]["depthSkipped"], 0)
        self.assertGreater(data["coverageSummary"]["skipCounts"]["prunedDirectories"], 0)
        self.assertIn("Top-N omitted matches", report.render(data))
        limited = self.scanner(max_entries=1).scan()
        self.assertTrue(any(stage["status"] == "not-inspected" for stage in limited["discoveryStages"]))
        self.assertIn("not-inspected", report.render(limited))

    def test_nested_mount_is_skipped_and_target_size_partial(self):
        root = self.file("Library/Caches/mounted/nested/data.bin").parents[1]
        scanner = self.scanner()
        scanner.ownership = {"paths": set()}
        original = scan.metadata.DirectoryScope.metadata
        def synthetic_mount(scope, name):
            info = original(scope, name)
            if name == "nested":
                values = {key: getattr(info, key) for key in
                          ("st_mode", "st_dev", "st_ino", "st_mtime", "st_size", "st_nlink", "st_blocks")}
                values["st_dev"] += 1
                return SimpleNamespace(**values)
            return info
        with patch.object(scan.metadata.DirectoryScope, "metadata", synthetic_mount):
            item = scanner.measure({"path": str(root), "category": "app-cache", "owner": None,
                                    "protected": False, "evidence": {}})
        self.assertEqual(item["coverage"], "partial")
        self.assertIsNone(item["logicalBytes"])
        self.assertEqual(scanner.coverage[-1]["crossFilesystemSkipped"], 1)

    def test_target_association_uses_actual_device_not_workspace_assumption(self):
        cache = self.file("Library/Caches/fixture/a.bin").parent
        scanner = self.scanner()
        class Association:
            def __init__(self):
                self.seen = []
            def observe(self, path, expected_device=None):
                self.seen.append((path, expected_device))
                return str(expected_device) if expected_device is not None else None
            def evidence(self):
                return {"filesystems": [], "scopes": [], "limitations": []}
        scanner.space = Association()
        data = scanner.scan()
        row = next(row for row in data["items"] if row["path"] == str(cache))
        self.assertEqual(row["filesystemId"], str(cache.stat().st_dev))
        self.assertIn((str(cache), cache.stat().st_dev), scanner.space.seen)

    def test_render_escapes_control_and_markdown_in_filenames(self):
        self.file("Library/Caches/line\n`markup`|name/a.bin")
        text = report.render(self.scanner().scan())
        self.assertNotIn("line\n`markup`", text)
        self.assertIn(r"line\n\u0060markup\u0060\|name", text)

    def test_sparse_logical_size_is_not_relabelled_as_allocation(self):
        path = self.file("Library/Caches/sparse/sparse.bin", b"")
        with path.open("wb") as handle:
            handle.truncate(8 * 1024 * 1024)
        data = self.scanner().scan()
        item = next(row for row in data["items"] if row["path"] == str(path.parent))
        self.assertEqual(item["logicalBytes"], 8 * 1024 * 1024)
        self.assertEqual(item["allocatedBytes"], path.stat().st_blocks * 512)
        self.assertIsNone(item["estimatedReclaimableBytes"])

    def test_inaccessible_and_below_threshold_scopes_remain_visible_in_summary(self):
        path = self.file("Library/Caches/blocked/file.bin").parent
        original = scan.metadata.root_scope
        @contextmanager
        def deny(root, *args, **kwargs):
            if root == str(path):
                raise PermissionError("fixture")
            with original(root, *args, **kwargs) as scope:
                yield scope
        with patch.object(scan.metadata, "root_scope", deny):
            data = self.scanner().scan()
        self.assertIn("inaccessible", data["coverageSummary"]["statusCounts"])
        self.assertIn("allocated unknown", report.render(data))
        scanner = self.scanner()
        scanner.minimum = 50 * 1024 * 1024
        data = scanner.scan()
        self.assertEqual(data["belowThresholdTargets"], 1)
        self.assertEqual(data["items"], [])

    def test_cli_rejects_discovery_baseline_as_operation_snapshot(self):
        snapshot = {"purpose": "read-only-macos-space-snapshot", "filesystemSpace": {}}
        discovery = {"purpose": "read-only-macos-discovery", "filesystemSpace": {}}
        with patch.object(report, "load", side_effect=[snapshot, discovery]), patch("sys.stderr"):
            with self.assertRaises(SystemExit):
                report.main(["render", "--input", "after.json", "--before", "scan.json"])


if __name__ == "__main__":
    unittest.main()
