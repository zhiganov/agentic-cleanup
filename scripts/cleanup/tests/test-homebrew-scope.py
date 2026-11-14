#!/usr/bin/env python3
"""Exercise the documented read-only Homebrew probes with isolated fake tools."""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = (ROOT / "skills/agentic-cleanup/references/workflow.md").read_text(encoding="utf-8")
HOMEBREW = WORKFLOW.split("**Homebrew:**", 1)[1].split("**MacPorts:**", 1)[0]


def bash_recipe(marker):
    matches = [code for code in re.findall(r"```bash\n(.*?)\n```", HOMEBREW, re.S)
               if marker in code]
    assert len(matches) == 1, marker
    return matches[0]


DISCOVER = bash_recipe("# Homebrew cache discovery (read-only)")
PREVIEW = bash_recipe("# Homebrew maintenance preview (read-only; readiness checks required)")


@unittest.skipUnless(os.name == "posix" and Path("/bin/bash").is_file(), "POSIX Bash fixtures")
class HomebrewScope(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cleanup-homebrew-fixture-")
        self.addCleanup(self.temp.cleanup)
        # macOS /var and /tmp are aliases; use a physical fixture root so the
        # recipe's ancestor-link guard is exercised rather than bypassed.
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.cache = self.root / "Configured cache with spaces"
        (self.cache / "downloads").mkdir(parents=True)
        (self.cache / "downloads/installed-bottle").write_bytes(b"retained installed download")
        (self.cache / "downloads/stale-bottle").write_bytes(b"old download")
        self.cellar = self.root / "Cellar/example"
        for version in ("1.0", "2.0"):
            (self.cellar / version).mkdir(parents=True)
            (self.cellar / version / "tool").write_bytes(version.encode())
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + os.pathsep + os.defpath,
                        HOMEBREW_CACHE=str(self.cache), FIXTURE_LOG=str(self.log),
                        FIXTURE_USAGE="102400", FIXTURE_PREVIEW="Would remove: stale download (1 MiB)")
        self.write_tool("brew", '''
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FIXTURE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "brew", "args": args,
                         "no_auto_update": os.environ.get("HOMEBREW_NO_AUTO_UPDATE"),
                         "no_analytics": os.environ.get("HOMEBREW_NO_ANALYTICS")}) + "\\n")
if args == ["--cache"]:
    if os.environ.get("FIXTURE_METADATA_FAIL"):
        print("fixture metadata unavailable", file=sys.stderr)
        sys.exit(7)
    print(os.environ["HOMEBREW_CACHE"])
elif args == ["cleanup", "--dry-run", "--scrub"]:
    if os.environ.get("FIXTURE_PREVIEW_FAIL"):
        print("fixture preview unavailable", file=sys.stderr)
        sys.exit(8)
    print(os.environ["FIXTURE_PREVIEW"])
else:
    print("unexpected or mutating brew invocation", file=sys.stderr)
    sys.exit(99)
''')
        self.write_tool("du", '''
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FIXTURE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "du", "args": args}) + "\\n")
if len(args) != 2 or args[0] != "-Psk":
    sys.exit(99)
print(os.environ["FIXTURE_USAGE"] + "\\t" + args[1])
if os.environ.get("FIXTURE_USAGE_FAIL"):
    print("fixture partial measurement", file=sys.stderr)
    sys.exit(9)
''')

    def write_tool(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def invoke(self, code, **overrides):
        return subprocess.run(["/bin/bash", "-c", code], env=dict(self.env, **overrides),
                              text=True, capture_output=True, timeout=5)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_only_read_only_calls(self):
        for call in self.calls():
            if call["tool"] == "brew":
                self.assertIn(call["args"], (["--cache"], ["cleanup", "--dry-run", "--scrub"]))
                self.assertEqual(call["no_auto_update"], "1")
                self.assertEqual(call["no_analytics"], "1")
            else:
                self.assertEqual(call["tool"], "du")
                self.assertEqual(call["args"], ["-Psk", str(self.cache)])

    def snapshot_targets(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for root in (self.cache, self.cellar) for path in root.rglob("*") if path.is_file()}

    def test_custom_cache_root_is_honored_without_default_or_downloads_double_count(self):
        result = self.invoke(DISCOVER)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Cache root: {self.cache}", result.stdout)
        self.assertIn("Cache usage (KiB, scope only): 102400", result.stdout)
        self.assertEqual([call["args"] for call in self.calls() if call["tool"] == "du"],
                         [["-Psk", str(self.cache)]])
        self.assertNotIn("Library/Caches/Homebrew", result.stdout)
        self.assert_only_read_only_calls()

    def test_retained_installed_downloads_do_not_become_a_recovery_estimate(self):
        before = self.snapshot_targets()
        discovery = self.invoke(DISCOVER)
        preview = self.invoke(PREVIEW, FIXTURE_PREVIEW=f"Would remove: {self.cache}/downloads/stale-bottle (1 MiB)")
        self.assertEqual(discovery.returncode, 0, discovery.stderr)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn("Reclaimable bytes: unknown", discovery.stdout)
        self.assertIn("selectable=false; excluded from all", discovery.stdout)
        self.assertNotIn("installed-bottle", preview.stdout)
        self.assertEqual(self.snapshot_targets(), before)
        self.assert_only_read_only_calls()

    def test_preview_including_an_old_installed_version_stays_manual_only(self):
        before = self.snapshot_targets()
        discovery = self.invoke(DISCOVER)
        preview = self.invoke(PREVIEW, FIXTURE_PREVIEW=f"Would remove: {self.cellar}/1.0 (12 files, 1 MiB)")
        self.assertEqual(discovery.returncode, 0, discovery.stderr)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn("manual-only; selectable=false", discovery.stdout)
        self.assertIn(str(self.cellar / "1.0"), preview.stdout)
        self.assertEqual(self.snapshot_targets(), before)
        self.assert_only_read_only_calls()

    def test_preview_is_data_not_a_deletion_command(self):
        sentinel = self.root / "must-not-exist"
        result = self.invoke(PREVIEW, FIXTURE_PREVIEW=f"Would remove: $(touch '{sentinel}')")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("$(touch", result.stdout)
        self.assertFalse(sentinel.exists())
        self.assert_only_read_only_calls()

    def test_metadata_failure_does_not_fall_back_to_default_root(self):
        result = self.invoke(DISCOVER, FIXTURE_METADATA_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown; metadata failed", result.stderr)
        self.assertFalse(any(call["tool"] == "du" for call in self.calls()))

    def test_invalid_and_profile_wide_cache_roots_are_not_measured(self):
        for cache in ("", "/", str(self.home), "relative/cache", str(self.cache) + "/../other", "/bad\nroot"):
            with self.subTest(cache=cache):
                self.log.unlink(missing_ok=True)
                result = self.invoke(DISCOVER, HOMEBREW_CACHE=cache)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call["tool"] == "du" for call in self.calls()))

    def test_linked_root_or_ancestor_is_not_followed(self):
        alias = self.root / "cache-alias"
        alias.symlink_to(self.cache, target_is_directory=True)
        for cache in (alias, alias / "downloads"):
            with self.subTest(cache=cache):
                result = self.invoke(DISCOVER, HOMEBREW_CACHE=str(cache))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("linked scope skipped", result.stderr)
                self.assertFalse(any(call["tool"] == "du" for call in self.calls()))

    def test_unavailable_cache_remains_unknown_not_empty(self):
        result = self.invoke(DISCOVER, HOMEBREW_CACHE=str(self.root / "absent"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown; root absent or inaccessible (not a cleanup target)", result.stderr)
        self.assertNotIn("Cache usage (KiB, scope only)", result.stdout)
        self.assertFalse(any(call["tool"] == "du" for call in self.calls()))

    def test_non_directory_cache_root_is_not_measured(self):
        path = self.root / "file-not-a-cache-directory"
        path.write_bytes(b"fixture")
        result = self.invoke(DISCOVER, HOMEBREW_CACHE=str(path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown; not a directory", result.stderr)
        self.assertEqual(path.read_bytes(), b"fixture")
        self.assertFalse(any(call["tool"] == "du" for call in self.calls()))

    def test_failed_or_malformed_usage_is_unknown_not_partial_or_zero(self):
        for overrides in ({"FIXTURE_USAGE_FAIL": "1"}, {"FIXTURE_USAGE": "not-a-size"}):
            with self.subTest(overrides=overrides):
                result = self.invoke(DISCOVER, **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Cache usage: unknown", result.stderr)
                self.assertNotIn("Cache usage (KiB, scope only)", result.stdout)

    def test_preview_failure_remains_unavailable_without_retry_or_cleanup(self):
        result = self.invoke(PREVIEW, FIXTURE_PREVIEW_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture preview unavailable", result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assert_only_read_only_calls()

    def test_all_active_consumers_preserve_the_manual_only_boundary(self):
        for relative in ("skills/agentic-cleanup/SKILL.md", "skills/agentic-cleanup/references/workflow.md",
                         "README.md", "CLAUDE.md", "cleanup-gist.md"):
            with self.subTest(document=relative):
                text = " ".join((ROOT / relative).read_text(encoding="utf-8").lower().split())
                self.assertIn("manual-only", text)
                self.assertIn("`all`", text)
                self.assertNotIn("brew cleanup -s", text)
                self.assertIn("wholesale cache deletion", text)
        normalized = " ".join(HOMEBREW.lower().split())
        for contract in ("already verified, working homebrew/ruby installation", "no install, update, upgrade or build is active",
                         "preview unavailable/manual-required", "do not bootstrap ruby", "never convert preview lines into deletion commands",
                         "installed current/newest/pinned/live versions", "refreshed target identity", "manual-required"):
            self.assertIn(contract, normalized)
        self.assertNotIn("--prune=all", HOMEBREW)
        self.assertIn("not a second selectable App Caches entry", WORKFLOW)


if __name__ == "__main__":
    unittest.main()
