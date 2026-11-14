#!/usr/bin/env python3
"""Disposable POSIX/macOS fixtures; never scan a workstation or launch an app."""
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "scripts/cleanup"))
import macos_scan as scan
import macos_ownership as ownership


@unittest.skipUnless(os.name == "posix", "POSIX descriptor fixtures")
class MacDiscovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cleanup-macos-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.work = self.root / "workspace"
        (self.work / ".opencode").mkdir(parents=True)
        self.apps = self.root / "Applications"
        self.apps.mkdir()
        self.process = ownership.no_processes()
        self.process["modelHost"] = False
        self.secret = "opaque-fixture-secret-DO-NOT-OUTPUT"

    def file(self, relative, data=b"fixture-data", base=None):
        path = (base or self.home) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def scanner(self, **kwargs):
        return scan.Scanner(str(self.home), str(self.work), env={}, application_roots=[str(self.apps)],
                            system_config=str(self.root / "managed"), process=self.process,
                            tool_probe=False, space_probe=False, minimum_bytes=1, **kwargs)

    def item(self, report, path):
        return next(row for row in report["items"] if row["path"] == str(path))

    def app(self, bundle="org.fixture.Space", name="Space App"):
        self.file(name + ".app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": bundle, "CFBundleName": name}), self.apps)

    def test_outermost_workspace_excludes_home_and_reports_nearer_marker(self):
        nested = self.work / "project/.opencode"
        nested.mkdir(parents=True)
        (self.home / ".opencode").mkdir()
        scanner = self.scanner()
        scanner.cwd = str(nested.parent)
        resolved = scanner.resolve_workspace()
        self.assertEqual(resolved["root"], str(self.work))
        self.assertEqual(resolved["nearerMarker"], str(nested.parent))
        scanner.cwd = str(self.home)
        self.assertFalse(scanner.resolve_workspace()["scoped"])

    def test_bundle_owner_spaces_unicode_and_exact_sandbox_cache_only(self):
        self.app(name="Space Äpp")
        cache = self.file("Library/Caches/org.fixture.Space/data.bin").parent
        sandbox = self.file("Library/Containers/org.fixture.Space/Data/Library/Caches/data.bin").parent
        private = self.file("Library/Containers/org.fixture.Space/Data/Documents/private.txt", self.secret.encode())
        self.file("Library/Group Containers/org.fixture.Space/private.txt", self.secret.encode())
        result = self.scanner().scan()
        self.assertEqual(self.item(result, cache)["owner"], "Space Äpp")
        self.assertEqual(self.item(result, sandbox)["category"], "sandbox-cache")
        self.assertNotIn(str(private), json.dumps(result))
        self.assertTrue(all("Group Containers" not in row["path"] for row in result["items"]))

    def test_payload_contents_are_never_opened(self):
        self.app()
        self.file("Library/Caches/org.fixture.Space/private.txt", self.secret.encode())
        original = os.open
        def open_metadata(path, flags, *args, **kwargs):
            if not flags & os.O_DIRECTORY and flags & os.O_ACCMODE == os.O_RDONLY:
                self.assertNotEqual(os.fspath(path), "private.txt", "Payload content opened")
            return original(path, flags, *args, **kwargs)
        with patch("os.open", side_effect=open_metadata):
            result = self.scanner().scan()
        self.assertNotIn(self.secret, json.dumps(result))

    def test_custom_tool_cache_does_not_replace_metadata_with_default_assumption(self):
        custom = self.file("custom pip cache/data.bin").parent
        self.file("Library/Caches/pip/old.bin")
        scanner = self.scanner()
        scanner.env["PIP_CACHE_DIR"] = str(custom)
        result = scanner.scan()
        pip = [row for row in result["items"] if row["category"] == "pip-cache"]
        self.assertEqual([row["path"] for row in pip], [str(custom)])

    def test_npmrc_reads_only_cache_field_and_never_outputs_token(self):
        cache = self.file("custom npm/_cacache/data.bin").parent.parent
        self.file(".npmrc", f"//registry.test/:_authToken={self.secret}\ncache={cache}\n".encode())
        result = self.scanner().scan()
        self.assertEqual(self.item(result, cache / "_cacache")["category"], "npm-cache")
        self.assertNotIn(self.secret, json.dumps(result))

    def test_open_path_is_protected_but_empty_census_never_makes_items_selectable(self):
        cache = self.file("Library/Caches/live/data.bin").parent
        self.process["paths"].add(str(cache / "data.bin"))
        result = self.scanner().scan()
        self.assertEqual(self.item(result, cache)["classification"], "live-dependency")
        self.assertTrue(all(row["selectable"] is False for row in result["items"]))
        self.assertEqual(result["processCensus"]["status"], "unsupported")

    def test_registered_but_idle_mcp_protects_sibling_dependencies_and_hides_config(self):
        project = self.work / "project with spaces"
        target = self.file("project with spaces/node_modules/pkg/index.js", base=self.work).parents[1]
        self.file(".config/opencode/opencode.jsonc", (
            '{ // comment\n"mcp":{"servers":{"' + self.secret + '":{"type":"local",'
            '"command":["node",' + json.dumps(str(project / "dist/server.js")) + '],'
            '"environment":{"TOKEN":"' + self.secret + '"},}, // trailing comment\n}},}'
        ).encode())
        result = self.scanner().scan()
        row = self.item(result, target)
        self.assertTrue(row["evidence"]["registeredMcpOwner"])
        self.assertEqual(row["classification"], "live-dependency")
        self.assertNotIn(self.secret, json.dumps(result))

    def test_claude_project_registration_is_protected_without_a_process(self):
        target = self.file("nested/node_modules/pkg/index.js", base=self.work).parents[1]
        source = {"projects": {str(target.parent): {"mcpServers": {self.secret: {
            "command": "node", "args": [str(target.parent / "dist/server.js")]}}}}}
        self.file(".claude.json", json.dumps(source).encode())
        result = self.scanner().scan()
        self.assertTrue(self.item(result, target)["evidence"]["registeredMcpOwner"])
        self.assertNotIn(self.secret, json.dumps(result))

    def test_monorepo_registration_protects_nested_package_dependencies(self):
        (self.work / "monorepo/.git").mkdir(parents=True)
        target = self.file("monorepo/packages/server/node_modules/pkg/index.js", base=self.work).parents[1]
        self.file(".config/opencode/opencode.json", json.dumps({"mcp": {"servers": {"fixture": {
            "type": "local", "command": ["node", str(self.work / "monorepo/dist/server.js")]}}}}).encode())
        row = self.item(self.scanner().scan(), target)
        self.assertEqual(row["evidence"]["project"], str(self.work / "monorepo"))
        self.assertTrue(row["evidence"]["registeredMcpOwner"])

    def test_unresolved_shell_or_environment_registration_is_partial_not_absent(self):
        for server in ({"type": "local", "command": ["sh", "-c", self.secret]},
                       {"type": "local", "command": ["node", "{env:MISSING}/server.js"]},
                       {"type": "local", "command": ["npx", "-y", "@fixture/server"]}):
            self.file(".config/opencode/opencode.json", json.dumps({"mcp": {"servers": {self.secret: server}}}).encode())
            result = self.scanner().scan()
            self.assertEqual(result["registeredMcp"]["status"], "partial")
            self.assertNotIn(self.secret, json.dumps(result))

    def test_malformed_config_never_dumps_source_or_exception_body(self):
        self.file(".config/opencode/opencode.json", ('{"mcp":' + self.secret).encode())
        result = self.scanner().scan()
        self.assertEqual(result["registeredMcp"]["status"], "partial")
        self.assertNotIn(self.secret, json.dumps(result))

    def test_jsonc_preserves_urls_quoted_comment_markers_and_trailing_comments(self):
        data = ownership.jsonc(b'{"url":"https://example.test/a,}","text":"/*literal*/", // hi\n}')
        self.assertEqual(data["url"], "https://example.test/a,}")
        self.assertEqual(data["text"], "/*literal*/")

    def test_multiple_release_families_keep_current_newest_live_and_unknown_versions(self):
        for family in ("standalone", "app-server-daemon"):
            base = self.home / ".codex/packages" / family
            for version in ("0.9.0", "0.10.0", "0.11.0", "unparsed-version"):
                self.file(f".codex/packages/{family}/releases/{version}/bin/tool")
            (base / "current").symlink_to("releases/0.10.0")
            self.file(f".codex/packages/{family}/auto-update-version", b"0.10.0")
        result = self.scanner().scan()
        for row in result["items"]:
            if row["category"] == "runtime-release":
                name = Path(row["path"]).name
                self.assertEqual(row["classification"], "human-review" if name == "0.9.0" else "protected")
                self.assertEqual(row["evidence"]["pinOwnership"], "unknown")

    def test_all_discovered_pnpm_generations_are_inventoried_not_just_active(self):
        for version in ("v3", "v10"):
            self.file(f"Library/pnpm/store/{version}/data.bin")
        rows = [row for row in self.scanner().scan()["items"] if row["category"] == "pnpm-store-generation"]
        self.assertEqual({Path(row["path"]).name for row in rows}, {"v3", "v10"})
        self.assertTrue(all(row["evidence"]["pinOwnership"] == "unknown" for row in rows))

    def test_hardlinks_are_deduplicated_and_unique_recovery_stays_unknown(self):
        path = self.file("Library/Caches/hardlinks/a.bin", b"1234567")
        os.link(path, path.parent / "b.bin")
        row = self.item(self.scanner().scan(), path.parent)
        self.assertEqual(row["logicalBytes"], 7)
        self.assertEqual(row["sharedFiles"], 1)
        self.assertIsNone(row["estimatedReclaimableBytes"])

    def test_specific_cache_override_cannot_escape_protected_or_homebrew_parent(self):
        for parent, expected in (("Homebrew", "manual-only"), ("com.apple.fixture", "protected")):
            cache = self.file(f"Library/Caches/{parent}/pip/data.bin").parent
            scanner = self.scanner()
            scanner.env["PIP_CACHE_DIR"] = str(cache)
            row = self.item(scanner.scan(), cache)
            self.assertEqual(row["classification"], expected)
            self.assertFalse(row["selectable"])

    def test_linked_cache_root_and_descendant_are_not_followed(self):
        outside = self.file("outside/secret.bin", self.secret.encode(), self.root).parent
        cache = self.home / "Library/Caches"
        cache.mkdir(parents=True)
        (cache / "linked").symlink_to(outside)
        physical = self.file("Library/Caches/physical/a.bin").parent
        (physical / "linked").symlink_to(outside)
        result = self.scanner().scan()
        self.assertEqual(self.item(result, physical)["coverage"], "partial")
        self.assertNotIn(str(outside), json.dumps(result))
        self.assertTrue(any(row["status"] == "linked-skipped" for row in result["coverage"]))

    def test_inaccessible_scope_is_unknown_not_zero(self):
        cache = self.file("Library/Caches/blocked/a.bin").parent
        original = scan.metadata.root_scope
        @contextmanager
        def blocked(path, *args, **kwargs):
            if str(path) == str(cache):
                raise PermissionError("fixture")
            with original(path, *args, **kwargs) as scope:
                yield scope
        with patch.object(scan.metadata, "root_scope", blocked):
            result = self.scanner().scan()
        row = self.item(result, cache)
        self.assertEqual(row["coverage"], "inaccessible")
        self.assertIsNone(row["logicalBytes"])
        self.assertIsNone(row["allocatedBytes"])

    def test_depth_entry_and_top_n_bounds_are_disclosed(self):
        for index in range(3):
            self.file(f"Library/Caches/cache-{index}/a/b/c/data.bin")
        result = self.scanner(max_depth=1, limit=1).scan()
        self.assertEqual(len(result["items"]), 1)
        self.assertGreaterEqual(result["omittedMatches"], 2)
        self.assertTrue(any(row.get("depthSkipped", 0) for row in result["coverage"]))
        result = self.scanner(max_entries=1).scan()
        self.assertEqual(result["status"], "partial")
        self.assertIn("discovery-entry-limit", result["warnings"])

    def test_dataless_metadata_is_not_opened_or_reported_as_zero_allocation(self):
        info = SimpleNamespace(st_file_attributes=0, st_flags=0x40000000, st_mode=stat.S_IFREG)
        self.assertEqual(scan.metadata.allocated_bytes("not-opened", info), (None, "cloud-placeholder-not-probed"))
        info.st_mode = stat.S_IFDIR
        with self.assertRaises(scan.metadata.BoundarySkipped):
            scan.metadata.check_directory(info)

    def test_process_probe_redacts_arguments_and_preserves_positive_open_paths(self):
        cache = self.file("Library/Caches/probed/a.bin").parent
        def run(args, **kwargs):
            if args[-1] == "pid=,ppid=,comm=":
                return 0, "100 1 /fixture/opencode\n101 100 /fixture/node\n"
            if args[-1] == "pid=,command=":
                return 0, "101 node /fixture/server.js --token=" + self.secret + "\n"
            return 0, "p101\nn" + str(cache / "a.bin") + "\n"
        result = ownership.processes(run)
        self.assertTrue(ownership.live(str(cache), result))
        self.assertNotIn(self.secret, json.dumps(result["summary"]))
        self.assertEqual(result["summary"]["status"], "partial")

    def test_census_includes_coordinator_ancestor_without_model_self_matching(self):
        def run(args, **kwargs):
            if args[-1] == "pid=,ppid=,comm=":
                return 0, f"100 1 /fixture/opencode\n{os.getpid()} 100 /fixture/python\n"
            if args[-1] == "pid=,command=":
                return 0, f"100 opencode /fixture/service.js\n{os.getpid()} python scanner huggingface\n"
            return 0, ""
        result = ownership.processes(run)
        self.assertEqual(result["summary"]["runtimeCounts"].get("opencode"), 1)
        self.assertFalse(result["modelHost"])

    def test_installers_manifest_and_runtime_inventory_include_both_modules(self):
        import re
        import shlex
        shell = (ROOT / "install.sh").read_text()
        powershell = (ROOT / "install.ps1").read_text()
        bash_contracts = shlex.split(re.search(r"contract_files=\((.*?)\)", shell, re.S)[1].replace("\\\n", ""))
        ps_contracts = re.findall(r"'([^']+)'", re.search(r"\$contracts = @\((.*?)\)", powershell, re.S)[1])
        self.assertEqual(set(bash_contracts), set(ps_contracts))
        workflow = (ROOT / "skills/agentic-cleanup/references/workflow.md").read_text()
        preamble = workflow.split("```bash\n", 1)[1].split("\n```", 1)[0]
        for module in ("macos_scan.py", "macos_ownership.py", "macos_report.py"):
            self.assertIn(module, bash_contracts)
            self.assertIn(module, preamble)

    def test_command_output_budget_owns_and_reaps_only_its_worker(self):
        with self.assertRaises(TimeoutError):
            ownership.command([sys.executable, "-c", "print('fixture' * 100)"], max_bytes=10)

    @unittest.skipUnless(sys.platform == "darwin", "Native macOS installed-entrypoint fixture")
    def test_isolated_installer_integrity_and_installed_cli(self):
        env = {"PATH": os.environ["PATH"], "HOME": str(self.home), "TMPDIR": str(self.root),
               "CLAUDE_CONFIG_DIR": str(self.root / "unselected-claude"),
               "XDG_CONFIG_HOME": str(self.home / ".config"), "XDG_DATA_HOME": str(self.home / ".local/share"),
               "AGENTIC_CLEANUP_RUNTIME": "opencode", "AGENTIC_CLEANUP_REPO_URL": ROOT.as_uri(),
               "OPENCODE_TERMINAL": "1"}
        installed = subprocess.run(["/bin/bash", str(ROOT / "install.sh")], env=env, cwd=self.work,
                                   capture_output=True, text=True, timeout=20)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertFalse((self.root / "unselected-claude").exists())
        payload = self.home / ".local/share/agentic-cleanup"
        workflow = (self.home / ".config/opencode/skills/agentic-cleanup/references/workflow.md").read_text()
        preamble = workflow.split("```bash\n", 1)[1].split("\n```", 1)[0]
        verified = subprocess.run(["/bin/bash", "-c", preamble], env=env, cwd=self.work,
                                  capture_output=True, text=True, timeout=10)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.file("Library/Caches/fixture/a.bin", b"x" * (1024 * 1024 + 1))
        for index in range(600):
            self.file(f"Library/pnpm/store/v3/{index:04d}.bin", b"")
        output = self.root / "scan.json"
        command = [sys.executable, str(payload / "scripts/cleanup/macos_scan.py"), "--home", str(self.home),
                   "--cwd", str(self.work), "--applications", str(self.apps), "--system-config-root", str(self.root / "managed"),
                   "--no-process-probe", "--no-tool-probe", "--no-space-probe", "--minimum-mib", "1",
                   "--max-entries", "300", "--output", str(output)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(output.read_text())
        self.assertEqual(report["purpose"], "read-only-macos-discovery")
        self.assertEqual(report["processCensus"]["status"], "unsupported")
        self.assertIn("tool-native-metadata-probing-disabled", report["warnings"])
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertTrue(report["items"])
        self.assertEqual(report["measurementScheduling"]["method"], "remaining-budget-share-single-pass")
        self.assertLessEqual(report["entriesVisited"], 300)
        store = self.item(report, self.home / "Library/pnpm/store/v3")
        self.assertEqual(store["coverage"], "root-entry-limit")
        self.assertIsNone(store["logicalBytes"])
        self.assertEqual(self.item(report, self.home / "Library/Caches/fixture")["coverage"], "complete")
        before = output.read_bytes()
        repeated = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual(output.read_bytes(), before)
        rendered = subprocess.run([sys.executable, str(payload / "scripts/cleanup/macos_report.py"),
                                   "render", "--input", str(output)], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn("not a full-drive census", rendered.stdout)
        self.assertIn("space is unknown", rendered.stdout)
        snapshot = self.root / "space.json"
        observed = subprocess.run([sys.executable, str(payload / "scripts/cleanup/macos_report.py"),
                                  "snapshot", "--path", "/", "--path", str(self.work), "--output", str(snapshot)],
                                  env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(observed.returncode, 0, observed.stderr)
        space = json.loads(snapshot.read_text())["filesystemSpace"]
        expected_ids = set()
        for path in (Path("/"), self.work):
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                expected_ids.add(str(os.fstatvfs(fd).f_fsid))
            finally:
                os.close(fd)
        self.assertEqual({row["filesystemId"] for row in space["filesystems"]}, expected_ids)
        self.assertTrue(all(row["status"] == "observed" for row in space["scopes"]))
        self.assertTrue(all(row["identityStatus"] == "verified-device" for row in space["filesystems"]))
        self.assertEqual(stat.S_IMODE(snapshot.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
