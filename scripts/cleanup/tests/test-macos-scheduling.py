#!/usr/bin/env python3
"""Disposable metadata fixtures for single-pass, bounded measurement scheduling."""
import os
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_scan as scan
import macos_report as report
from macos_ownership import no_processes


@unittest.skipUnless(os.name == "posix", "POSIX descriptor fixtures")
class Scheduling(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cleanup-scheduling-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home, self.work = self.root / "home", self.root / "workspace"
        self.home.mkdir()
        (self.work / ".opencode").mkdir(parents=True)

    def file(self, relative, data=b"fixture"):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def scanner(self, **kwargs):
        return scan.Scanner(self.home, self.work, env={}, application_roots=[],
                            system_config=str(self.root / "managed"), process=no_processes(),
                            tool_probe=False, space_probe=False, minimum_bytes=1, **kwargs)

    def item(self, data, path):
        return next(row for row in data["items"] if row["path"] == str(path))

    def test_large_early_store_cannot_starve_later_known_caches(self):
        store = self.home / "Library/pnpm/store/v3"
        for index in range(600):
            self.file(f"Library/pnpm/store/v3/{index:04d}.bin")
        later = self.file("Library/Caches/z-later-app/data.bin").parent
        automation = self.file("Library/Caches/ms-playwright/data.bin").parent
        data = self.scanner(max_entries=300).scan()
        self.assertEqual(self.item(data, store)["coverage"], "root-entry-limit")
        self.assertIsNone(self.item(data, store)["logicalBytes"])
        self.assertGreater(self.item(data, store)["observedLogicalBytes"], 0)
        self.assertEqual(self.item(data, later)["coverage"], "complete")
        self.assertEqual(self.item(data, automation)["coverage"], "complete")
        self.assertLessEqual(data["entriesVisited"], 300)
        self.assertTrue(all(row["selectable"] is False for row in data["items"]))
        self.assertTrue(all(row["estimatedReclaimableBytes"] is None for row in data["items"]))
        self.assertEqual(data["measurementScheduling"]["method"], "remaining-budget-share-single-pass")
        self.assertGreater(data["measurementScheduling"]["perRootLimitedTargets"], 0)
        self.assertIn("root-entry-limit", report.render(data))

    def spec(self, path, category="app-cache", protected=False, **evidence):
        return {"path": str(path), "category": category, "owner": None,
                "protected": protected, "evidence": evidence}

    def prepare_measurement(self, **kwargs):
        scanner = self.scanner(**kwargs)
        scanner.ownership = {"paths": set()}
        return scanner

    def test_root_slice_releases_all_pins_and_keeps_observed_subtotals_unknown(self):
        cache = self.file("cache/one/a.bin").parents[1]
        self.file("cache/two/b.bin")
        scanner = self.prepare_measurement()
        descriptors = set()
        original_open, original_close = os.open, os.close
        def opened(*args, **kwargs):
            fd = original_open(*args, **kwargs)
            descriptors.add(fd)
            return fd
        def closed(fd):
            descriptors.discard(fd)
            return original_close(fd)
        with patch("os.open", side_effect=opened), patch("os.close", side_effect=closed):
            item = scanner.measure(self.spec(cache), entry_budget=2, seconds_budget=5)
        self.assertEqual(descriptors, set())
        self.assertEqual(item["coverage"], "root-entry-limit")
        self.assertEqual(item["measurementBudget"]["entriesVisited"], 2)
        self.assertIsNone(item["logicalBytes"])
        self.assertIsNone(item["allocatedBytes"])
        self.assertIsNone(scanner.root_entry_limit)
        self.assertIsNone(scanner.root_deadline)

    def test_root_time_slice_does_not_consume_later_target_or_extend_global_deadline(self):
        cache = self.file("early/a.bin").parent
        self.file("early/b.bin")
        self.file("early/c.bin")
        later = self.file("later/data.bin").parent
        scanner = self.prepare_measurement()
        scanner.deadline = 10
        clock = [0.0]
        original = scan.metadata.file_metadata
        @contextmanager
        def slow(parent, name):
            with original(parent, name) as values:
                clock[0] += 0.6  # synthetic elapsed metadata time; never sleep
                yield values
        with patch.object(scan.time, "monotonic", side_effect=lambda: clock[0]):
            with patch.object(scan.metadata, "file_metadata", slow):
                first = scanner.measure(self.spec(cache), entry_budget=100, seconds_budget=1)
            second = scanner.measure(self.spec(later), entry_budget=100, seconds_budget=1)
        self.assertEqual(first["coverage"], "root-timed-out")
        self.assertIsNone(first["logicalBytes"])
        self.assertGreater(first["observedLogicalBytes"], 0)
        self.assertEqual(second["coverage"], "complete")
        self.assertEqual(scanner.deadline, 10)
        self.assertIsNone(scanner.root_deadline)

    def test_global_entry_or_time_exhaustion_marks_unattempted_targets_unknown(self):
        cache = self.file("cache/data.bin").parent
        for reason in ("entry-limit", "timed-out"):
            with self.subTest(reason=reason):
                scanner = self.prepare_measurement()
                if reason == "entry-limit":
                    scanner.entries = scanner.max_entries
                else:
                    scanner.deadline = 0
                item = scanner.measure(self.spec(cache), entry_budget=10, seconds_budget=1)
                self.assertEqual(item["coverage"], reason)
                self.assertFalse(item["measurementAttempted"])
                self.assertEqual(item["measurementBudget"]["entriesVisited"], 0)
                self.assertIsNone(item["logicalBytes"])
                self.assertIsNone(item["allocatedBytes"])

    def test_owned_metadata_command_timeout_cannot_exceed_root_slice(self):
        scanner = self.prepare_measurement()
        scanner.deadline, scanner.root_deadline = 100, 0.001
        with patch.object(scan.time, "monotonic", return_value=0), \
                patch.object(scanner, "run", return_value=(0, "")) as run:
            scanner.bounded_command(["fixture-read-only-command"], seconds=3)
        self.assertGreater(run.call_args.kwargs["seconds"], 0)
        self.assertLessEqual(run.call_args.kwargs["seconds"], 0.001)
        self.assertEqual(scanner.deadline, 100)

    def test_less_global_entries_than_targets_never_raises_the_limit(self):
        targets = [self.file(f"cache-{index}/data.bin").parent for index in range(8)]
        scanner = self.scanner(max_entries=3)
        scanner.discover_runtimes = lambda: [scanner.add(path, "app-cache") for path in targets]
        scanner.discover_tools = scanner.discover_apps = scanner.discover_caches = scanner.discover_workspace = lambda: None
        data = scanner.scan()
        self.assertLessEqual(data["entriesVisited"], 3)
        self.assertGreater(data["measurementScheduling"]["unmeasuredTargets"], 0)
        self.assertTrue(all(row["logicalBytes"] is None for row in data["items"] if not row["measurementAttempted"]))
        self.assertEqual(len(data["items"]), len(targets))

    def test_small_or_absent_targets_return_budget_without_revisiting_large_scopes(self):
        small = self.file("a-small/data.bin").parent
        large = self.home / "b-large"
        for index in range(40):
            self.file(f"b-large/{index}.bin")
        scanner = self.scanner(max_entries=40)
        scanner.discover_runtimes = lambda: [scanner.add(path, "app-cache") for path in
                                           (self.home / "a-absent", small, large)]
        scanner.discover_tools = scanner.discover_apps = scanner.discover_caches = scanner.discover_workspace = lambda: None
        original = scanner.measure
        measured = []
        def once(spec, **kwargs):
            measured.append(spec["path"])
            return original(spec, **kwargs)
        with patch.object(scanner, "measure", side_effect=once):
            data = scanner.scan()
        self.assertEqual(len(measured), 3)
        self.assertEqual(len(measured), len(set(measured)))
        first = self.item(data, small)
        last = self.item(data, large)
        self.assertGreater(last["measurementBudget"]["entryLimit"], first["measurementBudget"]["entryLimit"])
        self.assertEqual(first["coverage"], "complete")
        self.assertIsNone(last["logicalBytes"])
        self.assertLessEqual(data["entriesVisited"], 40)

    def test_protection_ownership_inventory_top_n_and_threshold_reporting_survive_slices(self):
        for index in range(60):
            self.file(f"Library/pnpm/store/v3/{index}.bin")
        self.file("Library/pnpm/store/v10/data.bin")
        self.file(".local/share/claude/versions/1.0.0", b"old")
        current = self.file(".local/share/claude/versions/2.0.0", b"current")
        selector = self.home / ".local/bin/claude"
        selector.parent.mkdir(parents=True)
        selector.symlink_to(current)
        data = self.scanner(max_entries=300).scan()
        self.assertEqual(self.item(data, current)["classification"], "protected")
        runtime_scopes = [row for row in data["coverage"] if "/store/v" in row["path"] or "/versions/" in row["path"]]
        self.assertEqual(len(runtime_scopes), 4)
        self.assertTrue(any(row["status"] == "root-entry-limit" for row in runtime_scopes))
        limited = self.scanner(max_entries=300, limit=1).scan()
        self.assertGreater(limited["omittedMatches"], 0)
        self.assertGreater(limited["measurementScheduling"]["attemptedTargets"], 1)
        self.assertIn("Top-N omitted matches", report.render(limited))
        scanner = self.prepare_measurement()
        live_target = self.file("project/node_modules/pkg/data.bin").parents[1]
        scanner.ownership["paths"].add(str(live_target.parent / "dist/server.js"))
        live = scanner.measure(self.spec(live_target, "workspace-dependencies", project=str(live_target.parent)),
                               entry_budget=1, seconds_budget=2)
        self.assertEqual(live["classification"], "live-dependency")
        self.assertFalse(live["selectable"])
        self.assertIsNone(live["estimatedReclaimableBytes"])

    def test_threshold_and_summary_counts_include_only_observed_work(self):
        self.file("Library/Caches/tiny/data.bin")
        scanner = self.scanner()
        scanner.minimum = 50 * scan.MIB
        data = scanner.scan()
        self.assertEqual(data["belowThresholdTargets"], 1)
        self.assertEqual(data["omittedMatches"], 0)
        self.assertEqual(data["items"], [])
        scheduling = data["measurementScheduling"]
        self.assertEqual(scheduling["discoveryEntriesVisited"] + scheduling["measurementEntriesVisited"],
                         data["entriesVisited"])
        self.assertEqual(scheduling["targets"], scheduling["attemptedTargets"] + scheduling["unmeasuredTargets"])
        self.assertEqual(scheduling["unspentEntryBudget"], data["limits"]["maxEntries"] - data["entriesVisited"])
        text = report.render(data)
        self.assertIn("below-threshold complete targets: 1", text)

    def test_legacy_saved_report_renders_without_new_scheduling_fields(self):
        self.file("Library/Caches/fixture/data.bin")
        data = self.scanner().scan()
        data.pop("measurementScheduling")
        for item in data["items"]:
            item.pop("measurementBudget")
            item.pop("measurementAttempted")
        self.assertIn("legacy-sequential", report.render(data))


if __name__ == "__main__":
    unittest.main()
