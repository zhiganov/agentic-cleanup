#!/usr/bin/env python3
"""Bounded metadata-only file audit. Evidence only, never a deletion list.

Supply exact --root paths or --known-folder names. Online-only files are not
opened, links are not traversed, overlapping roots and file identities are
deduplicated. Unsupported allocation is null, not zero. No third-party packages.
"""
from __future__ import annotations

import argparse
import ctypes
import heapq
import json
import ntpath
import os
import stat
import time
from datetime import datetime, timezone

MIB = 1024 * 1024
KNOWN_FOLDERS = {
    "Desktop": "B4BFCC3A-DB2C-424C-B029-7FE99A87C641",
    "Documents": "FDD39AD0-238F-46AF-ADB4-6C85480369C7",
    "Downloads": "374DE290-123F-4565-9164-39C4925E467B",
    "Videos": "18989B1D-99B5-455B-841C-AB7C74E4DDFC",
    "Music": "4BD8D571-6D19-48D3-BE97-422220080E43",
    "Pictures": "33E28130-4E1E-4676-835A-98395C3BC3BB",
    "OneDrive": "A52BBA46-E9E1-435F-B3D9-28DAA648C0F6",
}
CLOUD_FLAGS = 0x1000 | 0x40000 | 0x400000  # offline / recall-on-open / recall-on-data
REPARSE = 0x400


def is_link(info):
    # Cloud reparse tags are metadata placeholders, not namespace redirects.
    cloud_tag = getattr(info, "st_reparse_tag", 0) & 0xFFFF0FFF == 0x9000001A
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & REPARSE and not cloud_tag)


def known_folders(names):
    """Resolve redirected folders using SHGetKnownFolderPath, without creating them."""
    if os.name != "nt":
        raise OSError("Windows known-folder resolution is unavailable")
    import uuid
    shell = ctypes.WinDLL("shell32", use_last_error=True)
    ole = ctypes.WinDLL("ole32", use_last_error=True)
    shell.SHGetKnownFolderPath.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                         ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    shell.SHGetKnownFolderPath.restype = ctypes.c_long
    ole.CoTaskMemFree.argtypes = [ctypes.c_void_p]
    results = []
    for name in names:
        guid = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID(KNOWN_FOLDERS[name]).bytes_le)
        pointer = ctypes.c_void_p()
        # DONT_VERIFY avoids touching remote paths or materializing redirected folders.
        code = shell.SHGetKnownFolderPath(ctypes.byref(guid), 0x4000, None, ctypes.byref(pointer))
        try:
            results.append({"name": name, "path": ctypes.wstring_at(pointer) if code == 0 else None,
                            "status": "resolved" if code == 0 else "unavailable"})
        finally:
            if pointer.value:
                ole.CoTaskMemFree(pointer)
    return results


def extended_path(path):
    path = ntpath.abspath(path)
    if path.startswith("\\\\?\\"):
        return path
    return "\\\\?\\UNC\\" + path[2:] if path.startswith("\\\\") else "\\\\?\\" + path


def allocated_bytes(path, info):
    """No content reads. Cloud recall flags are an unknown allocation measurement."""
    if getattr(info, "st_file_attributes", 0) & CLOUD_FLAGS:
        return None, "cloud-placeholder-not-probed"
    if is_link(info):
        return None, "linked-not-probed"
    if os.name != "nt":
        blocks = getattr(info, "st_blocks", None)
        return (blocks * 512, "stat-blocks") if blocks is not None else (None, "unsupported")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    if not getattr(info, "st_file_attributes", 0) & (0x800 | 0x200):
        class StandardInfo(ctypes.Structure):
            _fields_ = [("allocation", ctypes.c_int64), ("length", ctypes.c_int64),
                        ("links", ctypes.c_uint32), ("delete_pending", ctypes.c_ubyte),
                        ("directory", ctypes.c_ubyte)]
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                      ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.GetFileInformationByHandleEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        # Read attributes, all share modes, open existing, OPEN_REPARSE_POINT.
        # No data-read access. FileStandardInfo avoids estimating resident NTFS
        # allocation by rounding logical length to a guessed cluster size.
        handle = kernel.CreateFileW(extended_path(path), 0x80, 7, None, 3, 0x00200000, None)
        if handle in (None, ctypes.c_void_p(-1).value):
            return None, "allocation-api-failed"
        try:
            data = StandardInfo()
            if not kernel.GetFileInformationByHandleEx(handle, 1, ctypes.byref(data), ctypes.sizeof(data)):
                return None, "allocation-api-failed"
            return data.allocation, "windows-file-standard-info"
        finally:
            kernel.CloseHandle(handle)
    kernel.GetCompressedFileSizeW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
    kernel.GetCompressedFileSizeW.restype = ctypes.c_uint32
    high = ctypes.c_uint32()
    ctypes.set_last_error(0)
    low = kernel.GetCompressedFileSizeW(extended_path(path), ctypes.byref(high))
    if low == 0xFFFFFFFF and ctypes.get_last_error():
        return None, "allocation-api-failed"
    physical = (high.value << 32) | low
    return physical, "windows-physical-size"


def inside(path, root):
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:
        return False


def deduplicate_roots(roots):
    selected, coverage = [], []
    for raw in sorted(set(roots), key=lambda p: (len(os.path.abspath(p)), p)):
        path = os.path.abspath(raw)  # do not resolve or follow links
        key = os.path.normcase(path)
        owner = next((r for r in selected if inside(key, os.path.normcase(r))), None)
        if owner:
            coverage.append({"path": path, "status": "overlapping-root", "coveredBy": owner})
        else:
            selected.append(path)
    return selected, coverage


def audit(roots, minimum_bytes=50 * MIB, limit=100, max_seconds=60, max_entries=500000,
          measure=allocated_bytes, clock=time.monotonic):
    roots, coverage = deduplicate_roots(roots)
    deadline = clock() + max_seconds
    files = []
    identities = set()
    totals = {"logicalBytes": 0, "allocatedKnownBytes": 0, "unknownAllocationFiles": 0,
              "uniqueFiles": 0, "duplicateHardlinks": 0, "matchingFiles": 0,
              "estimatedReclaimableBytes": None}
    visited = 0
    for root in roots:
        root_record = {"path": root, "status": "complete", "entriesVisited": 0,
                       "linkedSkipped": 0, "inaccessibleSkipped": 0}
        coverage.append(root_record)
        # Check each existing ancestor, not only the root: a redirected path
        # through a junction is not permission to traverse its target.
        ancestor = root
        unsafe = False
        while ancestor:
            try:
                info = os.lstat(ancestor)
                if is_link(info):
                    unsafe = True
                    break
                if getattr(info, "st_file_attributes", 0) & CLOUD_FLAGS and stat.S_ISDIR(info.st_mode):
                    root_record["status"] = "cloud-directory-skipped"
                    unsafe = True
                    break
            except FileNotFoundError:
                if ancestor == root:
                    root_record["status"] = "absent"
                    unsafe = True
                    break
            except OSError:
                root_record["status"] = "inaccessible"
                unsafe = True
                break
            parent = os.path.dirname(ancestor)
            if parent == ancestor:
                break
            ancestor = parent
        if unsafe:
            if root_record["status"] == "complete":
                root_record["status"] = "linked-skipped"
            continue
        pending = [root]
        while pending:
            if clock() >= deadline or visited >= max_entries:
                root_record["status"] = "timed-out" if clock() >= deadline else "entry-limit"
                break
            directory = pending.pop()
            try:
                directory_info = os.lstat(directory)
                if is_link(directory_info) or getattr(directory_info, "st_file_attributes", 0) & CLOUD_FLAGS:
                    root_record["linkedSkipped"] += 1
                    continue
                with os.scandir(directory) as children:
                    for child in children:
                        if clock() >= deadline or visited >= max_entries:
                            root_record["status"] = "timed-out" if clock() >= deadline else "entry-limit"
                            break
                        visited += 1
                        root_record["entriesVisited"] += 1
                        try:
                            info = child.stat(follow_symlinks=False)
                            attributes = getattr(info, "st_file_attributes", 0)
                            if is_link(info):
                                root_record["linkedSkipped"] += 1
                                continue
                            if stat.S_ISDIR(info.st_mode):
                                if attributes & CLOUD_FLAGS:
                                    root_record["linkedSkipped"] += 1
                                else:
                                    pending.append(child.path)
                                continue
                            if not stat.S_ISREG(info.st_mode) or child.name.casefold() == "hiberfil.sys":
                                continue
                            # Windows DirEntry caches omit inode/device/link count.
                            # Refresh metadata through stat, without following links
                            # or opening content, before deduplicating file identity.
                            if not info.st_ino:
                                info = os.stat(child.path, follow_symlinks=False)
                                if is_link(info) or not stat.S_ISREG(info.st_mode):
                                    root_record["linkedSkipped"] += 1
                                    continue
                            identity = (info.st_dev, info.st_ino) if info.st_ino else child.path
                            if identity in identities:
                                totals["duplicateHardlinks"] += 1
                                continue
                            identities.add(identity)
                            allocation, method = measure(child.path, info)
                            totals["uniqueFiles"] += 1
                            totals["logicalBytes"] += info.st_size
                            if allocation is None:
                                totals["unknownAllocationFiles"] += 1
                            else:
                                totals["allocatedKnownBytes"] += allocation
                            if info.st_size >= minimum_bytes:
                                totals["matchingFiles"] += 1
                                row = {"path": child.path, "logicalBytes": info.st_size,
                                       "allocatedBytes": allocation, "allocationMethod": method,
                                       "estimatedReclaimableBytes": None, "linkCount": info.st_nlink,
                                       "disposition": "human-review"}
                                rank = (info.st_size, child.path, row)
                                if len(files) < limit:
                                    heapq.heappush(files, rank)
                                elif rank[:2] > files[0][:2]:
                                    heapq.heapreplace(files, rank)
                        except OSError:
                            root_record["inaccessibleSkipped"] += 1
            except OSError:
                root_record["inaccessibleSkipped"] += 1
            if root_record["status"] != "complete":
                break
        if root_record["status"] == "complete" and (root_record["inaccessibleSkipped"] or root_record["linkedSkipped"]):
            root_record["status"] = "partial"
    return {"schemaVersion": "1.0", "purpose": "read-only-file-discovery",
            "createdAt": datetime.now(timezone.utc).isoformat(), "measurementMethod": "filesystem-metadata",
            "minimumBytes": minimum_bytes, "coverage": coverage, "totals": totals,
            "omittedMatches": max(0, totals["matchingFiles"] - len(files)),
            "files": [row for _, _, row in sorted(files, key=lambda x: x[:2], reverse=True)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--known-folder", choices=KNOWN_FOLDERS, action="append", default=[])
    parser.add_argument("--minimum-mib", type=int, default=50)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--max-seconds", type=int, default=60)
    parser.add_argument("--max-entries", type=int, default=500000)
    parser.add_argument("--output", required=True, help="New private evidence file; never overwritten")
    args = parser.parse_args()
    if not args.root and not args.known_folder:
        parser.error("Select exact roots or known folders; no profile-wide default")
    if min(args.minimum_mib, args.limit, args.max_seconds, args.max_entries) <= 0:
        parser.error("Budgets and threshold must be positive")
    resolved = known_folders(args.known_folder) if args.known_folder else []
    result = audit(args.root + [r["path"] for r in resolved if r["path"]],
                   args.minimum_mib * MIB, args.limit, args.max_seconds, args.max_entries)
    result["knownFolders"] = resolved
    with open(args.output, "x", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)
        handle.write("\n")
    print(json.dumps({"status": "written", "uniqueFiles": result["totals"]["uniqueFiles"],
                      "matchingFiles": result["totals"]["matchingFiles"],
                      "omittedMatches": result["omittedMatches"]}))


if __name__ == "__main__":
    main()
