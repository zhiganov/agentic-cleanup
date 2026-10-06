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
import sys
import time
from contextlib import ExitStack, closing, contextmanager
from datetime import datetime, timezone
from types import SimpleNamespace

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
SCANDIR_SUPPORTS_FD = os.scandir in os.supports_fd


class BudgetExceeded(Exception):
    pass


class BoundarySkipped(OSError):
    def __init__(self, status):
        super().__init__(status)
        self.status = status


def check_directory(info):
    if is_link(info):
        raise BoundarySkipped("linked-skipped")
    if getattr(info, "st_file_attributes", 0) & CLOUD_FLAGS:
        raise BoundarySkipped("cloud-directory-skipped")
    if not stat.S_ISDIR(info.st_mode):
        raise BoundarySkipped("not-directory")


@contextmanager
def windows_pin(path, directory=True):
    """Pin a no-follow metadata handle. Caller must already pin all ancestors.

    Directory handles deny write/delete sharing, so neither rename nor
    SET_REPARSE_POINT can redirect subsequent pathname metadata calls.
    Busy directory scopes fail closed.
    Directory LIST_DIRECTORY participates in sharing checks; READ_ATTRIBUTES
    alone does not. File handles stay attribute-only and are queried by handle,
    never reopened by pathname for allocation. No file data is read.
    """
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                  ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.GetFileInformationByHandleEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    kernel.GetFileInformationByHandleEx.restype = ctypes.c_int
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(extended_path(path), 0x81 if directory else 0x80, 1, None, 3,
                                0x02000000 | 0x00200000 | 0x00100000, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        class AttributeTagInfo(ctypes.Structure):
            _fields_ = [("attributes", ctypes.c_uint32), ("tag", ctypes.c_uint32)]
        data = AttributeTagInfo()
        if not kernel.GetFileInformationByHandleEx(handle, 9, ctypes.byref(data), ctypes.sizeof(data)):
            raise ctypes.WinError(ctypes.get_last_error())
        info = SimpleNamespace(st_mode=stat.S_IFDIR if data.attributes & 0x10 else stat.S_IFREG,
                               st_file_attributes=data.attributes, st_reparse_tag=data.tag,
                               windows_handle=handle)
        if is_link(info):
            raise BoundarySkipped("linked-skipped")
        yield info
    finally:
        kernel.CloseHandle(handle)


class DirectoryScope:
    """Pinned directory plus parent-relative metadata/enumeration operations."""
    def __init__(self, path, descriptor=None):
        self.path, self.descriptor = path, descriptor

    def scandir(self):
        return os.scandir(self.path if self.descriptor is None else self.descriptor)

    def metadata(self, name):
        if self.descriptor is None:
            return os.stat(os.path.join(self.path, name), follow_symlinks=False)
        return os.stat(name, dir_fd=self.descriptor, follow_symlinks=False)


@contextmanager
def directory_scope(path, parent=None, expected=None):
    """Open only the immediate directory; its parent scope stays alive."""
    before = os.lstat(path) if parent is None else parent.metadata(os.path.basename(path))
    check_directory(before)
    if os.name == "nt":
        with windows_pin(path) as pinned:
            check_directory(pinned)
            current = os.stat(path, follow_symlinks=False)
            check_directory(current)
            if expected is not None and (current.st_dev, current.st_ino) != expected:
                raise BoundarySkipped("changed-skipped")
            yield DirectoryScope(path)
    else:
        # Unsupported descriptor APIs must not silently fall back to path walks.
        if not hasattr(os, "O_NOFOLLOW") or not SCANDIR_SUPPORTS_FD or os.stat not in os.supports_dir_fd:
            raise BoundarySkipped("unsupported-no-follow")
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(path if parent is None else os.path.basename(path), flags,
                             dir_fd=None if parent is None else parent.descriptor)
        try:
            current = os.fstat(descriptor)
            check_directory(current)
            if expected is not None and (current.st_dev, current.st_ino) != expected:
                raise BoundarySkipped("changed-skipped")
            yield DirectoryScope(path, descriptor)
        finally:
            os.close(descriptor)


@contextmanager
def root_scope(path, budget_check=lambda: None):
    # Pin from the filesystem/volume root DOWN. A leaf-only handle does not
    # protect a pathname against replacement of one of its ancestors.
    chain = [path]
    while os.path.dirname(chain[-1]) != chain[-1]:
        chain.append(os.path.dirname(chain[-1]))
    with ExitStack() as stack:
        parent = None
        for component in reversed(chain):
            budget_check()
            parent = stack.enter_context(directory_scope(component, parent))
        yield parent


def directory_entries(root, record, budget_check):
    """Depth-first walk, holding parent pins until all children are processed."""
    frames = []
    try:
        with root_scope(root, budget_check) as scope:
            frames.append((scope, scope.scandir(), None))
            while frames:
                budget_check()
                parent, children, _ = frames[-1]
                try:
                    child = next(children)
                except StopIteration:
                    _, iterator, pin = frames.pop()
                    iterator.close()
                    if pin is not None:
                        pin.__exit__(None, None, None)
                    continue
                yield parent, child.name
                try:
                    info = parent.metadata(child.name)
                    if not stat.S_ISDIR(info.st_mode) or is_link(info):
                        continue
                    budget_check()
                    pin = directory_scope(os.path.join(parent.path, child.name), parent,
                                          (info.st_dev, info.st_ino))
                    nested = pin.__enter__()
                    try:
                        iterator = nested.scandir()
                    except BaseException:
                        pin.__exit__(*sys.exc_info())
                        raise
                    frames.append((nested, iterator, pin))
                except BoundarySkipped:
                    record["linkedSkipped"] += 1
                except OSError:
                    record["inaccessibleSkipped"] += 1
    finally:
        # Includes exceptions, budgets and caller closing the generator.
        while frames:
            _, iterator, pin = frames.pop()
            try:
                iterator.close()
            finally:
                if pin is not None:
                    pin.__exit__(None, None, None)


@contextmanager
def file_metadata(parent, name):
    path = os.path.join(parent.path, name)
    info = parent.metadata(name)
    # Cloud placeholders use enumeration/stat metadata only; never open them.
    if os.name == "nt" and stat.S_ISREG(info.st_mode) and not is_link(info) and not getattr(info, "st_file_attributes", 0) & CLOUD_FLAGS:
        with windows_pin(path, directory=False) as pinned:
            if not stat.S_ISREG(pinned.st_mode):
                raise BoundarySkipped("changed-skipped")
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            class FileInfo(ctypes.Structure):
                _fields_ = [("attributes", ctypes.c_uint32), ("created", ctypes.c_uint32 * 2),
                            ("accessed", ctypes.c_uint32 * 2), ("written", ctypes.c_uint32 * 2),
                            ("volume", ctypes.c_uint32), ("size_high", ctypes.c_uint32),
                            ("size_low", ctypes.c_uint32), ("links", ctypes.c_uint32),
                            ("index_high", ctypes.c_uint32), ("index_low", ctypes.c_uint32)]
            kernel.GetFileInformationByHandle.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            kernel.GetFileInformationByHandle.restype = ctypes.c_int
            data = FileInfo()
            if not kernel.GetFileInformationByHandle(pinned.windows_handle, ctypes.byref(data)):
                raise ctypes.WinError(ctypes.get_last_error())
            # Legacy BY_HANDLE_FILE_INFORMATION indices can collide on ReFS.
            # Require the full original-handle identity; never reopen the name.
            class FileIdInfo(ctypes.Structure):
                _fields_ = [("volume", ctypes.c_uint64), ("identifier", ctypes.c_ubyte * 16)]
            kernel.GetFileInformationByHandleEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            kernel.GetFileInformationByHandleEx.restype = ctypes.c_int
            identity = FileIdInfo()
            if not kernel.GetFileInformationByHandleEx(pinned.windows_handle, 18, ctypes.byref(identity), ctypes.sizeof(identity)):
                raise ctypes.WinError(ctypes.get_last_error())
            pinned.st_size = (data.size_high << 32) | data.size_low
            pinned.st_dev = identity.volume
            pinned.st_ino = int.from_bytes(identity.identifier, 'little')
            pinned.st_nlink = data.links
            yield path, pinned
    else:
        yield path, info


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
    handle = getattr(info, "windows_handle", None)
    if handle is None:
        # Standalone callers get the same ancestry/no-follow guards as audit.
        try:
            with root_scope(os.path.dirname(os.path.abspath(path))) as parent:
                with file_metadata(parent, os.path.basename(path)) as (_, pinned):
                    if not stat.S_ISREG(pinned.st_mode):
                        return None, "changed-not-probed"
                    return allocated_bytes(path, pinned)
        except OSError:
            return None, "allocation-api-failed"
    kernel.GetFileInformationByHandleEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    kernel.GetFileInformationByHandleEx.restype = ctypes.c_int
    if not getattr(info, "st_file_attributes", 0) & (0x800 | 0x200):
        class StandardInfo(ctypes.Structure):
            _fields_ = [("allocation", ctypes.c_int64), ("length", ctypes.c_int64),
                        ("links", ctypes.c_uint32), ("delete_pending", ctypes.c_ubyte),
                        ("directory", ctypes.c_ubyte)]
        data = StandardInfo()
        if not kernel.GetFileInformationByHandleEx(handle, 1, ctypes.byref(data), ctypes.sizeof(data)):
            return None, "allocation-api-failed"
        return data.allocation, "windows-file-standard-info"
    class CompressionInfo(ctypes.Structure):
        _fields_ = [("physical", ctypes.c_int64), ("format", ctypes.c_uint16),
                    ("unit_shift", ctypes.c_ubyte), ("chunk_shift", ctypes.c_ubyte),
                    ("cluster_shift", ctypes.c_ubyte), ("reserved", ctypes.c_ubyte * 3)]
    data = CompressionInfo()
    if not kernel.GetFileInformationByHandleEx(handle, 8, ctypes.byref(data), ctypes.sizeof(data)):
        return None, "allocation-api-failed"
    return data.physical, "windows-file-compression-info"


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
    def budget_check():
        if clock() >= deadline:
            raise BudgetExceeded("timed-out")
        if visited >= max_entries:
            raise BudgetExceeded("entry-limit")

    for root in roots:
        root_record = {"path": root, "status": "complete", "entriesVisited": 0,
                       "linkedSkipped": 0, "inaccessibleSkipped": 0}
        coverage.append(root_record)
        try:
            with closing(directory_entries(root, root_record, budget_check)) as entries:
                for parent, name in entries:
                    visited += 1
                    root_record["entriesVisited"] += 1
                    try:
                        with file_metadata(parent, name) as (path, info):
                            if is_link(info):
                                root_record["linkedSkipped"] += 1
                                continue
                            if not stat.S_ISREG(info.st_mode) or name.casefold() == "hiberfil.sys":
                                continue
                            identity = (info.st_dev, info.st_ino) if info.st_ino else path
                            if identity in identities:
                                totals["duplicateHardlinks"] += 1
                                continue
                            allocation, method = measure(path, info)
                            identities.add(identity)
                            totals["uniqueFiles"] += 1
                            totals["logicalBytes"] += info.st_size
                            if allocation is None:
                                totals["unknownAllocationFiles"] += 1
                            else:
                                totals["allocatedKnownBytes"] += allocation
                            if info.st_size >= minimum_bytes:
                                totals["matchingFiles"] += 1
                                row = {"path": path, "logicalBytes": info.st_size,
                                       "allocatedBytes": allocation, "allocationMethod": method,
                                       "estimatedReclaimableBytes": None, "linkCount": info.st_nlink,
                                       "disposition": "human-review"}
                                rank = (info.st_size, path, row)
                                if len(files) < limit:
                                    heapq.heappush(files, rank)
                                elif rank[:2] > files[0][:2]:
                                    heapq.heapreplace(files, rank)
                    except BoundarySkipped:
                        root_record["linkedSkipped"] += 1
                    except OSError:
                        root_record["inaccessibleSkipped"] += 1
        except BudgetExceeded as error:
            root_record["status"] = str(error)
        except BoundarySkipped as error:
            root_record["status"] = error.status
        except FileNotFoundError:
            root_record["status"] = "absent"
        except OSError:
            root_record["inaccessibleSkipped"] += 1
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
