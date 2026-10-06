#!/usr/bin/env python3
"""Find non-overlapping large-path hotspots in a WizTree CSV export.

Usage:
    python find_outliers.py <csv> [--minimum-mb 100] [--limit 100]

The output is read-only discovery evidence, not a deletion list:

    directory|<sizeMB>|<path>
    file|<sizeMB>|<path>

The walker follows wrapper directories whose largest child accounts for most of
their size and stops at branch points. This surfaces recognizable resource roots
such as caches, node_modules, and build outputs without filling the result with
overlapping ancestors. hiberfil.sys is intentionally invisible: hibernation is
system functionality, never a cleanup candidate.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import ntpath
from dataclasses import dataclass, field
from pathlib import PureWindowsPath


MIB = 1024 * 1024
PROTECTED_BASENAMES = {"hiberfil.sys"}
RESOURCE_BOUNDARIES = {
    ".next",
    ".parcel-cache",
    ".turbo",
    ".vite",
    "cache",
    "cache2",
    "code cache",
    "gpucache",
    "node_modules",
    "npm-cache",
    "webviewcachex64",
}


@dataclass
class Entry:
    path: str
    size: int
    children: list["Entry"] = field(default_factory=list)
    allocated: int | None = None
    declared_directory: bool | None = None

    @property
    def key(self) -> str:
        return self.path.casefold()

    @property
    def name(self) -> str:
        return ntpath.basename(self.path.rstrip("\\"))

    @property
    def is_directory(self) -> bool:
        return self.declared_directory is True or bool(self.children)


def canonical_windows_path(raw: str) -> str:
    path = raw.strip().replace("/", "\\")
    if not path:
        return ""
    drive, tail = ntpath.splitdrive(path)
    if drive and tail in ("", "\\"):
        return drive + "\\"
    return path.rstrip("\\")


def parent_key(path: str) -> str | None:
    drive, tail = ntpath.splitdrive(path)
    if drive and tail == "\\":
        return None
    parent = canonical_windows_path(ntpath.dirname(path))
    if not parent or parent.casefold() == path.casefold():
        return None
    return parent.casefold()


def load_entries(csv_path: str) -> dict[str, Entry]:
    entries: dict[str, Entry] = {}
    allocated_column = None
    attributes_column = None
    with open(csv_path, encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        for row in reader:
            if len(row) < 2:
                continue
            path = canonical_windows_path(row[0])
            if path.casefold() in {"file name", "filename"}:
                columns = [cell.strip().casefold() for cell in row]
                allocated_column = columns.index("allocated") if "allocated" in columns else None
                attributes_column = columns.index("attributes") if "attributes" in columns else None
                continue
            if not path:
                continue
            try:
                size = int(row[1])
            except ValueError:
                continue
            if ntpath.basename(path.rstrip("\\")).casefold() in PROTECTED_BASENAMES:
                continue
            key = path.casefold()
            allocated = None
            if allocated_column is not None and len(row) > allocated_column:
                try:
                    value = int(row[allocated_column])
                    allocated = value if value >= 0 else None
                except ValueError:
                    pass
            directory = True if row[0].endswith(("\\", "/")) else None
            if attributes_column is not None and len(row) > attributes_column and row[attributes_column]:
                try:
                    directory = bool(int(row[attributes_column]) & 0x10)
                except ValueError:
                    directory = "D" in row[attributes_column].upper()
            existing = entries.get(key)
            if existing is None or size > existing.size:
                entries[key] = Entry(path=path, size=size, allocated=allocated, declared_directory=directory)

    for entry in entries.values():
        parent = entries.get(parent_key(entry.path) or "")
        if parent is not None:
            parent.children.append(entry)
    return entries


def is_drive_root(path: str) -> bool:
    drive, tail = ntpath.splitdrive(path)
    return bool(drive) and tail == "\\"


def path_depth(path: str) -> int:
    return len(PureWindowsPath(path).parts)


def select_hotspots(
    entries: dict[str, Entry],
    minimum_bytes: int,
    dominance: float,
    max_depth: int,
) -> list[Entry]:
    roots = [entry for entry in entries.values() if parent_key(entry.path) not in entries]
    selected: list[Entry] = []

    def walk(entry: Entry) -> None:
        if entry.size < minimum_bytes:
            return
        children = sorted(
            (child for child in entry.children if child.size >= minimum_bytes),
            key=lambda item: (-item.size, item.key),
        )
        if is_drive_root(entry.path) or path_depth(entry.path) <= 3 or entry.name.casefold() == ".cache":
            for child in children:
                walk(child)
            return

        boundary = entry.name.casefold() in RESOURCE_BOUNDARIES
        contains_boundary = any(child.name.casefold() in RESOURCE_BOUNDARIES for child in children)
        dominant = children and children[0].size >= entry.size * dominance
        if boundary or not children or (not dominant and not contains_boundary) or path_depth(entry.path) >= max_depth:
            selected.append(entry)
            return
        for child in children:
            walk(child)

    for root in sorted(roots, key=lambda item: (-item.size, item.key)):
        walk(root)
    return sorted(selected, key=lambda item: (-item.size, item.key))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path")
    parser.add_argument("--minimum-mb", type=int, default=100)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--dominance", type=float, default=0.80)
    parser.add_argument("--max-depth", type=int, default=9)
    parser.add_argument("--files", action="store_true", help="Independent largest-file report; no folder grouping or depth cap")
    parser.add_argument("--json", action="store_true", help="Labeled accounting and explicit top-N coverage")
    args = parser.parse_args()
    if args.minimum_mb <= 0 or args.limit <= 0:
        parser.error("--minimum-mb and --limit must be positive")
    if not 0 < args.dominance <= 1:
        parser.error("--dominance must be greater than 0 and at most 1")

    entries = load_entries(args.csv_path)
    hotspots = sorted((entry for entry in entries.values() if not entry.is_directory and entry.size >= args.minimum_mb * MIB),
                      key=lambda entry: (-entry.size, entry.key)) if args.files else select_hotspots(
        entries,
        minimum_bytes=args.minimum_mb * MIB,
        dominance=args.dominance,
        max_depth=args.max_depth,
    )
    if args.json:
        print(json.dumps({"schemaVersion": "1.0", "purpose": "read-only-file-discovery" if args.files else "read-only-folder-hotspots",
                          "measurementMethod": "wiztree-index", "coverage": "indexed-export-not-refreshed",
                          "matchingEntries": len(hotspots), "omittedMatches": max(0, len(hotspots) - args.limit),
                          "estimatedReclaimableBytes": None, "identityDeduplication": "unavailable-in-export",
                          "entries": [{"path": e.path, "kind": "directory" if e.is_directory else "file",
                                       "logicalBytes": e.size, "allocatedBytes": e.allocated,
                                       "allocationMethod": "wiztree-allocated-column" if e.allocated is not None else "unknown",
                                       "estimatedReclaimableBytes": None} for e in hotspots[:args.limit]]}, indent=2))
        return 0
    for entry in hotspots[: args.limit]:
        kind = "directory" if entry.is_directory else "file"
        print(f"{kind}|{entry.size // MIB}|{entry.path}")
    print(f"coverage: matched={len(hotspots)} omitted={max(0, len(hotspots) - args.limit)}; sizes=logical-MiB; reclaim=unknown", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
