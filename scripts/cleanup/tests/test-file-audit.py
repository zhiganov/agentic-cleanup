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
            self.assertIn("absent", [r["status"] for r in result["coverage"]])
            with patch("os.scandir", side_effect=PermissionError("fixture")):
                result = audit.audit([temp])
            self.assertEqual(result["coverage"][0]["status"], "partial")
            self.assertEqual(result["coverage"][0]["inaccessibleSkipped"], 1)
            ticks = iter([0, 100, 100])
            result = audit.audit([temp], clock=lambda: next(ticks), max_seconds=1)
            self.assertEqual(result["coverage"][0]["status"], "timed-out")

    def test_linked_root_is_never_followed(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            real = os.lstat
            def linked(path):
                if os.path.abspath(path) == os.path.abspath(temp):
                    return SimpleNamespace(st_mode=0o040755, st_file_attributes=0x400, st_reparse_tag=0xA0000003)
                return real(path)
            with patch("os.lstat", side_effect=linked), patch("os.scandir", side_effect=AssertionError("followed link")):
                result = audit.audit([temp])
            self.assertEqual(result["coverage"][0]["status"], "linked-skipped")

    def test_online_only_root_directory_is_not_enumerated(self):
        with tempfile.TemporaryDirectory(prefix="cleanup-files-test-") as temp:
            cloud = SimpleNamespace(st_mode=0o040755, st_file_attributes=0x400000 | 0x400,
                                    st_reparse_tag=0x9000001A)
            with patch("os.lstat", return_value=cloud), patch("os.scandir", side_effect=AssertionError("cloud enumeration")):
                result = audit.audit([temp])
            self.assertEqual(result["coverage"][0]["status"], "cloud-directory-skipped")

    def test_sparse_and_compressed_measurements(self):
        class NativeCall:
            def __init__(self, value): self.value = value
            def __call__(self, *args): return self.value
        kernel = SimpleNamespace(GetCompressedFileSizeW=NativeCall(4096), GetDiskFreeSpaceW=NativeCall(0))
        for flags in (0x200, 0x800):
            info = SimpleNamespace(st_file_attributes=flags, st_size=10**9, st_mode=0o100644)
            with patch("file_audit.os.name", "nt"), patch("ctypes.WinDLL", create=True, return_value=kernel), \
                 patch("ctypes.set_last_error", create=True), patch("ctypes.get_last_error", create=True, return_value=0):
                value, method = audit.allocated_bytes("C:\\fixture.bin", info)
            self.assertEqual(value, 4096)
            self.assertEqual(method, "windows-physical-size")
        kernel.GetCompressedFileSizeW.value = 0xFFFFFFFF
        with patch("file_audit.os.name", "nt"), patch("ctypes.WinDLL", create=True, return_value=kernel), \
             patch("ctypes.set_last_error", create=True), patch("ctypes.get_last_error", create=True, return_value=5):
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
