#!/usr/bin/env python3
"""Focused metadata/discovery regressions; only synthetic temp files."""
import csv
import ctypes
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

HELPERS = Path(__file__).resolve().parents[2] / "windows" / "cleanup"
sys.path.insert(0, str(HELPERS))
import file_audit as audit
spec = importlib.util.spec_from_file_location("audit_outliers", HELPERS / "find_outliers.py")
outliers = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = outliers
spec.loader.exec_module(outliers)


def make_link(link, target):
    if os.name == 'nt':
        subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(target)],
                       check=True, capture_output=True)
    else:
        link.symlink_to(target, target_is_directory=True)


def remove_link(link):
    if os.name == 'nt':
        subprocess.run(['cmd.exe', '/d', '/c', 'rmdir', str(link)], check=True, capture_output=True)
    else:
        link.unlink()


class FileAuditTests(unittest.TestCase):
    def test_known_folder_redirection_without_materialization(self):
        buffers = []
        class NativeCall:
            def __init__(self, action): self.action = action
            def __call__(self, *args): return self.action(*args)
        def resolve(guid, flags, token, output):
            self.assertEqual(flags, 0x4000)
            buffer = ctypes.create_unicode_buffer("C:\\fixture\\OneDrive\\Documents")
            buffers.append(buffer)
            ctypes.cast(output, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.cast(buffer, ctypes.c_void_p).value
            return 0
        shell = SimpleNamespace(SHGetKnownFolderPath=NativeCall(resolve))
        ole = SimpleNamespace(CoTaskMemFree=NativeCall(lambda pointer: None))
        with patch("file_audit.os.name", "nt"), patch("ctypes.WinDLL", create=True, side_effect=[shell, ole]):
            resolved = audit.known_folders(["Documents"])
        self.assertEqual(resolved[0]["path"], "C:\\fixture\\OneDrive\\Documents")
        self.assertEqual(resolved[0]["status"], "resolved")

    def test_native_allocation_for_only_a_fixture_file(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            file = Path(temp) / "allocated.bin"
            file.write_bytes(b"data" * 4096)
            allocation, method = audit.allocated_bytes(str(file), os.stat(file, follow_symlinks=False))
            self.assertIsInstance(allocation, int)
            self.assertGreaterEqual(allocation, 0)
            self.assertIn(method, ("windows-file-standard-info", "stat-blocks"))

    def test_nested_files_overlap_hardlinks_and_top_n(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            root = Path(temp)
            nested = root / "OneDrive" / "Documents" / "interviews" / "deep"
            nested.mkdir(parents=True)
            video = nested / "recording.mp4"
            video.write_bytes(b"v" * 101)
            os.link(video, root / "second-link.mp4")
            (root / "other.bin").write_bytes(b"a" * 90)
            # Opening input files would fail this test. scandir/stat are enough.
            with patch("builtins.open", side_effect=AssertionError("content read")):
                result = audit.audit([str(root), str(nested)], minimum_bytes=50, limit=1,
                                     measure=lambda p, s: (4096, "fixture-cluster-rounded"))
            self.assertEqual(result["totals"]["logicalBytes"], 191)
            self.assertEqual(result["totals"]["allocatedKnownBytes"], 8192)
            self.assertEqual(result["totals"]["duplicateHardlinks"], 1)
            self.assertEqual(result["omittedMatches"], 1)
            self.assertEqual(result["files"][0]["logicalBytes"], 101)
            self.assertIsNone(result["files"][0]["estimatedReclaimableBytes"])
            self.assertIn("overlapping-root", [r["status"] for r in result["coverage"]])

    def test_allocation_unknown_is_not_zero(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            (Path(temp) / "file.bin").write_bytes(b"data")
            result = audit.audit([temp], minimum_bytes=1, measure=lambda p, s: (None, "allocation-api-failed"))
            self.assertEqual(result["totals"]["unknownAllocationFiles"], 1)
            self.assertIsNone(result["files"][0]["allocatedBytes"])

    def test_cloud_metadata_is_not_probed(self):
        cloud = SimpleNamespace(st_file_attributes=0x400000 | 0x400, st_reparse_tag=0x9000001A,
                                st_mode=0o100644)
        with patch("ctypes.WinDLL", create=True, side_effect=AssertionError("cloud API probe")):
            self.assertEqual(audit.allocated_bytes("cloud.bin", cloud), (None, "cloud-placeholder-not-probed"))
        self.assertFalse(audit.is_link(cloud))
        cloud.st_reparse_tag = 0xA0000003
        self.assertTrue(audit.is_link(cloud))

    @unittest.skipUnless(os.name == 'nt', 'Native Windows cloud-open guard')
    def test_cloud_file_audit_never_opens_placeholder(self):
        with tempfile.TemporaryDirectory(prefix='cleanup-files-test-') as temp:
            (Path(temp) / 'cloud.bin').write_bytes(b'fixture')
            real_metadata, real_pin = audit.DirectoryScope.metadata, audit.windows_pin
            def metadata(scope, name):
                info = real_metadata(scope, name)
                if name == 'cloud.bin':
                    return SimpleNamespace(st_mode=info.st_mode, st_size=info.st_size,
                                           st_dev=info.st_dev, st_ino=info.st_ino, st_nlink=info.st_nlink,
                                           st_file_attributes=0x400000 | 0x400, st_reparse_tag=0x9000001A)
                return info
            @contextmanager
            def no_file_open(path, directory=True):
                self.assertTrue(directory, 'Cloud files must use enumeration/stat metadata only')
                with real_pin(path, directory=directory) as info:
                    yield info
            with patch.object(audit.DirectoryScope, 'metadata', metadata), patch('file_audit.windows_pin', no_file_open):
                result = audit.audit([temp], minimum_bytes=1)
            self.assertEqual(result['files'][0]['allocationMethod'], 'cloud-placeholder-not-probed')
            self.assertIsNone(result['files'][0]['allocatedBytes'])

    def test_extended_paths_and_long_names(self):
        self.assertEqual(audit.extended_path("C:\\very\\long\\file"), "\\\\?\\C:\\very\\long\\file")
        self.assertEqual(audit.extended_path("\\\\server\\share\\file"), "\\\\?\\UNC\\server\\share\\file")
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            nested = Path(temp).joinpath(*(["nested-directory"] * 18))
            nested.mkdir(parents=True)
            (nested / "deep.mp4").write_bytes(b"data")
            result = audit.audit([temp], minimum_bytes=1, measure=lambda p, s: (4, "fixture"))
            self.assertEqual(result["totals"]["matchingFiles"], 1)

    def test_budget_absence_and_inaccessible_coverage(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            root = Path(temp)
            (root / "a.bin").write_bytes(b"a")
            (root / "b.bin").write_bytes(b"b")
            result = audit.audit([temp, str(root.parent / "nonexistent-cleanup-fixture")], minimum_bytes=1,
                                 max_entries=1, measure=lambda p, s: (1, "fixture"))
            self.assertIn("entry-limit", [r["status"] for r in result["coverage"]])
            absent = audit.audit([str(root.parent / "nonexistent-cleanup-fixture")])
            self.assertEqual(absent["coverage"][0]["status"], "absent")
            with patch("os.scandir", side_effect=PermissionError("fixture")):
                result = audit.audit([temp])
            self.assertEqual(result["coverage"][0]["status"], "partial")
            self.assertEqual(result["coverage"][0]["inaccessibleSkipped"], 1)
            ticks = iter([0, 100, 100])
            result = audit.audit([temp], clock=lambda: next(ticks), max_seconds=1)
            self.assertEqual(result["coverage"][0]["status"], "timed-out")

    def test_linked_root_is_never_followed(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            base = Path(temp)
            outside, link = base / 'outside', base / 'selected'
            outside.mkdir()
            make_link(link, outside)
            try:
                with patch("os.scandir", side_effect=AssertionError("followed link")):
                    result = audit.audit([str(link)])
                self.assertEqual(result["coverage"][0]["status"], "linked-skipped")
            finally:
                remove_link(link)

    def test_online_only_root_directory_is_not_enumerated(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            cloud = SimpleNamespace(st_mode=0o040755, st_file_attributes=0x400000 | 0x400,
                                    st_reparse_tag=0x9000001A)
            with patch("os.lstat", return_value=cloud), patch("os.scandir", side_effect=AssertionError("cloud enumeration")):
                result = audit.audit([temp])
            self.assertEqual(result["coverage"][0]["status"], "cloud-directory-skipped")

    def test_replacement_during_enumeration_cannot_escape_or_leak_handles(self):
        for target_kind in ('root', 'ancestor', 'nested'):
            with self.subTest(target=target_kind), tempfile.TemporaryDirectory(prefix='cleanup-race-test-') as temp:
                base = Path(temp)
                root = base / 'ancestor' / 'selected'
                nested = root / 'nested'
                nested.mkdir(parents=True)
                (nested / 'inside.bin').write_bytes(b'fixture')
                outside = base / 'outside'
                (outside / 'selected' / 'nested').mkdir(parents=True)
                (outside / 'outside.bin').write_bytes(b'outside')
                (outside / 'selected' / 'nested' / 'outside.bin').write_bytes(b'outside')
                target = {'root': root, 'ancestor': root.parent, 'nested': nested}[target_kind]
                retained = base / 'retained'
                original = audit.DirectoryScope.scandir
                attempted, replaced, blocked = [], [], []
                def swap(scope):
                    if Path(scope.path) == nested and not attempted:
                        attempted.append(True)
                        try:
                            target.rename(retained)
                        except OSError:
                            blocked.append(True)
                        else:
                            make_link(target, outside)
                            replaced.append(True)
                    return original(scope)
                try:
                    with patch.object(audit.DirectoryScope, 'scandir', swap):
                        result = audit.audit([str(root)], minimum_bytes=1)
                    self.assertTrue(attempted)
                    self.assertEqual(result['totals']['matchingFiles'], 1)
                    self.assertEqual(Path(result['files'][0]['path']).name, 'inside.bin')
                    if os.name == 'nt':
                        self.assertTrue(blocked)
                        self.assertFalse(replaced)
                    # Closing the audit must release ALL ancestry/directory pins.
                    if replaced:
                        remove_link(target)
                        retained.rename(target)
                    target.rename(retained)
                    retained.rename(target)
                finally:
                    if replaced and target.is_symlink():
                        remove_link(target)

    @unittest.skipUnless(os.name == 'nt', 'Native Windows atomic no-follow open')
    def test_junction_inserted_between_check_and_pin_is_rejected(self):
        for nested_target in (False, True):
            with self.subTest(nested=nested_target), tempfile.TemporaryDirectory(prefix='cleanup-race-test-') as temp:
                base = Path(temp)
                root, outside, retained = base / 'selected', base / 'outside', base / 'retained'
                target = root / 'nested' if nested_target else root
                target.mkdir(parents=True)
                outside.mkdir()
                (outside / 'outside.bin').write_bytes(b'outside')
                real_pin = audit.windows_pin
                attempted = []
                @contextmanager
                def swap(path):
                    if Path(path) == target and not attempted:
                        attempted.append(True)
                        target.rename(retained)
                        make_link(target, outside)
                    with real_pin(path) as pinned:
                        yield pinned
                try:
                    with patch('file_audit.windows_pin', swap):
                        result = audit.audit([str(root)], minimum_bytes=1)
                    self.assertTrue(attempted)
                    self.assertEqual(result['totals']['matchingFiles'], 0)
                    self.assertIn(result['coverage'][0]['status'], ('linked-skipped', 'partial'))
                finally:
                    if attempted:
                        remove_link(target)

    @unittest.skipUnless(os.name == 'nt', 'Native Windows handle metadata')
    def test_allocation_uses_original_file_handle_and_pins_ancestors(self):
        with tempfile.TemporaryDirectory(prefix='cleanup-race-test-') as temp:
            base = Path(temp)
            root = base / 'selected'
            root.mkdir()
            file = root / 'inside.bin'
            file.write_bytes(b'fixture')
            outside = base / 'outside.bin'
            outside.write_bytes(b'outside' * 4096)
            expected, _ = audit.allocated_bytes(str(file), os.stat(file, follow_symlinks=False))
            attempted = []
            def measure(path, info):
                # Attribute-only file handles do not inhibit renames. Queries
                # must use that original handle, not the replacement pathname.
                attempted.append(True)
                try:
                    Path(path).rename(root / 'retained.bin')
                    os.link(outside, path)
                except OSError:
                    # A pinned ancestor may also inhibit child namespace writes.
                    pass
                with self.assertRaises(OSError):
                    root.rename(base / 'replacement')
                self.assertIsNotNone(info.windows_handle)
                return audit.allocated_bytes(path, info)
            result = audit.audit([str(root)], minimum_bytes=1, measure=measure)
            self.assertEqual(len(attempted), 1)
            self.assertEqual(result['totals']['matchingFiles'], 1)
            self.assertEqual(result['files'][0]['logicalBytes'], 7)
            self.assertEqual(result['files'][0]['allocatedBytes'], expected)
            file.rename(root / 'released.bin')
            root.rename(base / 'released')

    @unittest.skipUnless(os.name == 'nt', 'Native Windows write sharing')
    def test_busy_directory_is_partial_and_all_pins_are_released(self):
        with tempfile.TemporaryDirectory(prefix='cleanup-race-test-') as temp:
            root = Path(temp) / 'selected'
            nested = root / 'busy'
            nested.mkdir(parents=True)
            (nested / 'inside.bin').write_bytes(b'fixture')
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.restype = ctypes.c_void_p
            kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                          ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            handle = kernel.CreateFileW(str(nested), 0x40000000, 7, None, 3, 0x02000000, None)
            self.assertNotIn(handle, (None, ctypes.c_void_p(-1).value))
            try:
                result = audit.audit([str(root)], minimum_bytes=1)
                self.assertEqual(result['totals']['matchingFiles'], 0)
                self.assertEqual(result['coverage'][0]['status'], 'partial')
                self.assertGreater(result['coverage'][0]['inaccessibleSkipped'], 0)
            finally:
                kernel.CloseHandle(handle)
            nested.rename(root / 'released')
            root.rename(Path(temp) / 'released-root')

    def test_entry_limit_releases_nested_scopes(self):
        with tempfile.TemporaryDirectory(prefix='cleanup-race-test-') as temp:
            root = Path(temp) / 'selected'
            nested = root / 'nested'
            nested.mkdir(parents=True)
            (nested / 'inside.bin').write_bytes(b'fixture')
            result = audit.audit([str(root)], minimum_bytes=1, max_entries=2)
            self.assertEqual(result['coverage'][0]['status'], 'entry-limit')
            nested.rename(root / 'released')
            root.rename(Path(temp) / 'released-root')

    def test_timeout_and_measurement_error_release_nested_scopes(self):
        with tempfile.TemporaryDirectory(prefix='cleanup-race-test-') as temp:
            root = Path(temp) / 'selected'
            nested = root / 'nested'
            nested.mkdir(parents=True)
            (nested / 'inside.bin').write_bytes(b'fixture')
            now = [0]
            def measure(path, info):
                now[0] = 100
                return None, 'fixture'
            result = audit.audit([str(root)], minimum_bytes=1, max_seconds=1,
                                 clock=lambda: now[0], measure=measure)
            self.assertEqual(result['coverage'][0]['status'], 'timed-out')
            nested.rename(root / 'released')
            nested = root / 'released'
            def failure(path, info):
                raise RuntimeError('synthetic measurement failure')
            with self.assertRaises(RuntimeError), patch('file_audit.allocated_bytes', failure):
                audit.audit([str(root)], minimum_bytes=1, measure=failure)
            nested.rename(root / 'released-again')
            root.rename(Path(temp) / 'released-root')

    @unittest.skipUnless(os.name == 'nt', 'Native Windows sparse allocation API')
    def test_native_sparse_allocation_uses_original_handle(self):
        with tempfile.TemporaryDirectory(prefix='cleanup-files-test-') as temp:
            file = Path(temp) / 'sparse.bin'
            file.write_bytes(b'fixture')
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                          ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
            kernel.CreateFileW.restype = ctypes.c_void_p
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            kernel.DeviceIoControl.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32,
                                               ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
            handle = kernel.CreateFileW(str(file), 0x40000000, 7, None, 3, 0, None)
            self.assertNotIn(handle, (None, ctypes.c_void_p(-1).value))
            try:
                returned = ctypes.c_uint32()
                self.assertTrue(kernel.DeviceIoControl(handle, 0x900C4, None, 0, None, 0,
                                                       ctypes.byref(returned), None))
            finally:
                kernel.CloseHandle(handle)
            with file.open('r+b') as fixture:
                fixture.truncate(1024 * 1024)
            info = os.stat(file, follow_symlinks=False)
            self.assertTrue(info.st_file_attributes & 0x200)
            allocation, method = audit.allocated_bytes(str(file), info)
            self.assertEqual(method, 'windows-file-compression-info')
            self.assertIsInstance(allocation, int)
            self.assertLess(allocation, info.st_size)

    @unittest.skipUnless(os.name == 'nt', 'Native Windows full file identity')
    def test_full_identity_preserves_distinct_files_with_legacy_index_collision(self):
        with tempfile.TemporaryDirectory(prefix='cleanup-files-test-') as temp:
            root = Path(temp)
            first, second = root / 'first.bin', root / 'second.bin'
            first.write_bytes(b'first')
            second.write_bytes(b'second')
            os.link(first, root / 'hardlink.bin')
            real_kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            real_info = real_kernel.GetFileInformationByHandle
            real_info.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            real_info.restype = ctypes.c_int
            real_extended = real_kernel.GetFileInformationByHandleEx
            real_extended.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            real_extended.restype = ctypes.c_int
            class LegacyCollision:
                def __call__(self, handle, pointer):
                    result = real_info(handle, pointer)
                    if result:
                        words = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_uint32))
                        words[11], words[12] = 0, 1
                    return result
            class FullIdentity:
                def __call__(self, handle, kind, pointer, length):
                    result = real_extended(handle, kind, pointer, length)
                    if result and kind == 18:
                        words = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_uint64))
                        # Same low 64 bits, differing high 64 bits; hardlinks
                        # retain the same full identity from the native handle.
                        words[2], words[1] = words[1], 1
                    return result
            kernel = SimpleNamespace(CreateFileW=real_kernel.CreateFileW, CloseHandle=real_kernel.CloseHandle,
                                     GetFileInformationByHandleEx=FullIdentity(),
                                     GetFileInformationByHandle=LegacyCollision())
            with patch('ctypes.WinDLL', return_value=kernel):
                result = audit.audit([temp], minimum_bytes=1)
            self.assertEqual(result['coverage'][0]['status'], 'complete')
            self.assertEqual(result['totals']['uniqueFiles'], 2)
            self.assertEqual(result['totals']['duplicateHardlinks'], 1)
            self.assertEqual(result['totals']['logicalBytes'], 11)

    def test_sparse_and_compressed_measurements(self):
        class NativeCall:
            def __init__(self): self.success = 1
            def __call__(self, handle, kind, data, length):
                self.kind = kind
                ctypes.cast(data, ctypes.POINTER(ctypes.c_int64))[0] = 4096
                return self.success
        kernel = SimpleNamespace(GetFileInformationByHandleEx=NativeCall())
        for flags in (0x200, 0x800):
            info = SimpleNamespace(st_file_attributes=flags, st_size=10**9, st_mode=0o100644, windows_handle=123)
            with patch("file_audit.os.name", "nt"), patch("ctypes.WinDLL", create=True, return_value=kernel):
                value, method = audit.allocated_bytes("C:\\fixture.bin", info)
            self.assertEqual(value, 4096)
            self.assertEqual(method, "windows-file-compression-info")
            self.assertEqual(kernel.GetFileInformationByHandleEx.kind, 8)
        kernel.GetFileInformationByHandleEx.success = 0
        with patch("file_audit.os.name", "nt"), patch("ctypes.WinDLL", create=True, return_value=kernel):
            self.assertEqual(audit.allocated_bytes("C:\\fixture.bin", info), (None, "allocation-api-failed"))

    def test_individual_csv_report_does_not_group_nested_file(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            csv_path = Path(temp) / "index.csv"
            with csv_path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.writer(handle)
                writer.writerow(["File Name", "Size", "Allocated", "Attributes"])
                writer.writerow(["C:\\Users\\dev\\OneDrive\\Documents\\", 200 * audit.MIB, 100 * audit.MIB, 16])
                writer.writerow(["C:\\Users\\dev\\OneDrive\\Documents\\deep\\interview.mp4", 120 * audit.MIB, 64 * audit.MIB, 32])
                writer.writerow(["C:\\Users\\dev\\OneDrive\\Documents\\second.mp4", 60 * audit.MIB, "", 32])
            result = subprocess.run([sys.executable, str(HELPERS / "find_outliers.py"), str(csv_path),
                                     "--files", "--json", "--minimum-mb", "50", "--limit", "1"],
                                    capture_output=True, text=True, check=True)
            report = json.loads(result.stdout)
            self.assertTrue(report["entries"][0]["path"].endswith("interview.mp4"))
            self.assertEqual(report["entries"][0]["allocatedBytes"], 64 * audit.MIB)
            self.assertEqual(report["omittedMatches"], 1)
            self.assertIsNone(report["estimatedReclaimableBytes"])
            entries = outliers.load_entries(str(csv_path))
            self.assertIsNone(next(e for e in entries.values() if e.path.endswith("second.mp4")).allocated)


if __name__ == "__main__":
    unittest.main()
