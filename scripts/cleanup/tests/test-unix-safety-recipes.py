#!/usr/bin/env python3
"""Instruction consistency checks, not a Unix cleanup executor test."""

import os
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
DOCUMENTS = {
    "entry": "skills/agentic-cleanup/SKILL.md",
    "workflow": "skills/agentic-cleanup/references/workflow.md",
    "guidance": "CLAUDE.md",
    "readme": "README.md",
    "portable": "cleanup-gist.md",
    "windows_guidance": "scripts/windows/cleanup/README.md",
}
TEXT = {name: (REPO_ROOT / path).read_text(encoding="utf-8")
        for name, path in DOCUMENTS.items()}


def compact(text):
    lines = (line.lstrip().removeprefix(">") for line in text.lower().splitlines())
    return " ".join(" ".join(lines).split())


def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


def assert_denial_contract(text):
    normalized = compact(text)
    assert "stop the blocked operation" in normalized or "stop a denied operation" in normalized
    assert "never change syntax, wrappers or tools to evade" in normalized
    for unsafe in (
        "when you hit such a block, substitute",
        "so its delete commands never hit the hook",
        "same result, no pattern collision",
        "the launcher carries no delete keywords so the hook passes",
        "so the deletes (inside the file) pass",
    ):
        assert unsafe not in normalized, unsafe


def assert_cache_contract(text):
    normalized = compact(text)
    assert "closed" in normalized
    assert "owner/process" in normalized
    assert "live-path" in normalized
    assert "review-only" in normalized
    assert "open or locked files" in normalized or "open/locked files" in normalized
    assert "preserv" in normalized and "root" in normalized
    assert "skip locked files silently" not in normalized
    assert "locked files just get skipped" not in normalized
    assert "`fcntl`-locked files skip silently" not in normalized
    assert "will silently fail to delete" not in normalized


class UnixSafetyRecipes(unittest.TestCase):
    def test_permission_denials_are_respected_in_all_active_consumers(self):
        for name, text in TEXT.items():
            with self.subTest(document=name):
                assert_denial_contract(text)

    def test_denial_guard_rejects_a_syntax_substitution_regression(self):
        with self.assertRaises(AssertionError):
            assert_denial_contract(TEXT["workflow"] + "\nWhen you hit such a block, substitute find -delete.")

    def test_app_and_browser_recipes_require_closed_owners_and_fresh_evidence(self):
        workflow = TEXT["workflow"]
        recipes = (
            section(workflow, "#### Category: App Caches (", "#### Category: System Package Manager Cache (Linux"),
            section(workflow, "#### Category: Browser Caches (Linux", "#### Category: System Package Manager Cache (macOS"),
            section(workflow, "#### Category: Browser Caches (macOS", "### Step 4:"),
            section(workflow, "| App caches |", "\n| Windows.old |"),
            section(workflow, "| Browser caches (Linux) |", "\n| System pkg manager cache (macOS) |"),
            section(workflow, "| Browser caches (macOS) |", "\n\n"),
            section(TEXT["portable"], "### App caches", "### Downloaded models"),
        )
        for recipe in recipes:
            with self.subTest(recipe=recipe[:80]):
                assert_cache_contract(recipe)

    def test_incomplete_owner_evidence_is_not_a_safe_to_delete_result(self):
        self.assertIn("incomplete evidence stays review-only", compact(TEXT["entry"]))
        for name in ("workflow", "guidance", "portable"):
            self.assertIn("incomplete evidence stays review-only", compact(TEXT[name]))

    def test_cache_guard_rejects_the_old_lock_skip_assumption(self):
        recipe = section(TEXT["workflow"], "#### Category: Browser Caches (macOS", "### Step 4:")
        with self.assertRaises(AssertionError):
            assert_cache_contract(recipe + "\nLocked files just get skipped.")

    def test_live_runtime_cache_cannot_be_selected_as_an_app_cache(self):
        recipe = section(TEXT["workflow"], "**Self-protection:**", "Collect: app/directory name")
        self.assertIn("live dependency, not a selectable app-cache target", compact(recipe))
        self.assertIn("does not override liveness protection", compact(recipe))

    def test_agent_history_is_not_a_debris_target(self):
        workflow = TEXT["workflow"]
        debris = section(workflow, "#### Category: Claude Code Debris", "#### Category: Downloaded Model Caches")
        self.assertIn("do not offer", compact(debris))
        self.assertIn("~/.claude/projects/*/*.jsonl", debris)
        self.assertIn("~/.claude/file-history/", debris)
        self.assertIn("regardless of age", compact(debris))
        self.assertNotIn("-mtime +28", debris)
        self.assertNotIn("LastWriteTime older than 28 days", debris)
        command = section(workflow, "| Claude Code debris |", "\n| Downloaded model caches |")
        self.assertIn("preserve all conversation/session logs, file-edit history", compact(command))
        self.assertNotIn("delete selected old", compact(command))
        for name in ("entry", "guidance", "readme", "portable"):
            with self.subTest(document=name):
                self.assertIn("regardless of age", compact(TEXT[name]))
                self.assertNotIn("files older than 28 days", TEXT[name])

    def test_measurements_dispatch_by_platform_and_target_filesystem(self):
        workflow = TEXT["workflow"]
        measure = section(workflow, "#### Free-space measurement (platform dispatch)", "**Take a session census")
        self.assertIn("**Windows:**", measure)
        self.assertIn("diskspace.ps1", measure)
        self.assertIn("**macOS:**", measure)
        self.assertIn("**Linux:**", measure)
        self.assertIn("macos_report.py snapshot", measure)
        self.assertIn("fstatvfs", measure)
        self.assertIn("validates that block device", measure)
        self.assertIn('df -Pk "<selected path or verified existing parent>"', measure)
        self.assertIn("no powershell or windows helper is required on unix", compact(measure))
        self.assertIn("unknown, never zero", compact(measure))
        for start, end in (("### Step 6:", "For each selected category"),
                           ("### Step 7:", "**Compute `freed")):
            step = section(workflow, start, end)
            with self.subTest(step=start):
                self.assertIn("Free-space measurement (platform dispatch)", step)
                self.assertIn("Windows", step)
                self.assertIn("macOS", step)
                self.assertIn("Linux", step)
                self.assertIn("macos_report.py snapshot", step)
                self.assertIn("df -Pk", step)
                self.assertIn("unknown", step)
        self.assertIn("same recorded filesystem", compact(TEXT["portable"]))

    def test_historical_examples_defer_to_the_current_safety_contract(self):
        for relative in ("docs/2026-03-11-cleanup-design.md",
                         "docs/plans/2026-03-11-cleanup-implementation.md"):
            with self.subTest(document=relative):
                header = compact((REPO_ROOT / relative).read_text(encoding="utf-8").split("\n\n", 2)[1])
                self.assertIn("safety examples are superseded", header)
                self.assertIn("governing skill", header)
                self.assertIn("protected regardless of age", header)

    @unittest.skipUnless(os.name == "posix", "POSIX open-file lifetime demonstration")
    def test_open_advisory_locked_file_can_be_unlinked_in_disposable_fixture(self):
        import fcntl

        # This proves the recipe cannot use a lock as a veto. It does not test
        # or authorize deleting any real cache, and invokes no cleanup command.
        with tempfile.TemporaryDirectory(prefix="cleanup-lock-fixture-") as tmp:
            path = Path(tmp) / "cache-entry"
            path.write_bytes(b"fixture")
            with path.open("r+b") as opened:
                fcntl.lockf(opened, fcntl.LOCK_EX | fcntl.LOCK_NB)
                path.unlink()
                self.assertFalse(path.exists())
                self.assertEqual(opened.read(), b"fixture")


if __name__ == "__main__":
    unittest.main()
