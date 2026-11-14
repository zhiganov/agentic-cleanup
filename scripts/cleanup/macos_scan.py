#!/usr/bin/env python3
"""Read-only, bounded macOS cache/runtime inventory. Never a cleanup plan."""
from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
from macos_ownership import (absolute, command, live, mcp_ownership, metadata,
                             no_processes, processes, read_metadata, within)
from macos_report import Filesystems, coverage_summary, write_private

MIB = 1024 * 1024
MARKERS = (".claude", ".opencode", "opencode.json", "opencode.jsonc")
PROJECT_TARGETS = {"node_modules", ".next", ".turbo", ".parcel-cache", ".vite"}
PRUNE = PROJECT_TARGETS | {".git", ".venv", "venv", "vendor", "target", "__pycache__"}
APP_ALIASES = {"com.spotify.client": "Spotify", "Google": "Google Chrome",
               "zen": "Zen", "Steam": "Steam", "com.hnc.Discord": "Discord"}
SUPPORT = {"Google/Chrome": "Google Chrome", "Chromium": "Chromium",
           "BraveSoftware/Brave-Browser": "Brave Browser", "Microsoft Edge": "Microsoft Edge",
           "Vivaldi": "Vivaldi", "Arc/User Data": "Arc", "com.operasoftware.Opera": "Opera"}
ELECTRON = {"Cursor": "Cursor", "Code": "Visual Studio Code", "Slack": "Slack",
            "discord": "Discord", "Notion": "Notion", "Claude": "Claude"}


class Scanner:
    def __init__(self, home, cwd, env=None, application_roots=None, system_config=None,
                 max_seconds=45, max_entries=250000, max_depth=20, limit=100,
                 minimum_bytes=50 * MIB, process=None, run=command, tool_probe=True, space_probe=True):
        self.home, self.cwd = absolute(home), absolute(cwd)
        self.env = dict(os.environ if env is None else env)
        self.apps = application_roots if application_roots is not None else ["/Applications", self.path("Applications")]
        self.system_config = system_config or "/Library/Application Support/opencode"
        self.deadline = time.monotonic() + max_seconds
        self.max_seconds, self.max_entries, self.max_depth = max_seconds, max_entries, max_depth
        self.limit, self.minimum = limit, minimum_bytes
        self.entries, self.coverage, self.targets, self.warnings = 0, [], {}, []
        self.run, self.tool_probe = run, tool_probe
        self.space = Filesystems(self.bounded_command, self.check) if space_probe else None
        self.process = process
        self.app_names, self.app_labels, self.sources = {}, set(), set()
        self.project_scopes = {}
        self.global_ids, self.global_logical, self.global_allocated = set(), 0, 0
        self.global_unknown = 0
        self.workspace = self.resolve_workspace()

    def path(self, relative):
        return os.path.join(self.home, relative)

    def check(self):
        if time.monotonic() >= self.deadline:
            raise metadata.BudgetExceeded("timed-out")
        if self.entries >= self.max_entries:
            raise metadata.BudgetExceeded("entry-limit")

    def bounded_command(self, args, seconds=5, **kwargs):
        self.check()
        remaining = max(0.01, self.deadline - time.monotonic())
        return self.run(args, seconds=min(seconds, remaining), **kwargs)

    def record(self, path, status, **extra):
        self.coverage.append({"path": absolute(path), "status": status, **extra})

    def children(self, path):
        result = []
        record = {"path": absolute(path), "status": "discovering"}
        self.coverage.append(record)
        try:
            with metadata.root_scope(absolute(path), self.check) as scope:
                with scope.scandir() as children:
                    for entry in children:
                        self.check()
                        self.entries += 1
                        try:
                            info = scope.metadata(entry.name)
                        except OSError:
                            self.record(os.path.join(path, entry.name), "inaccessible-or-changed")
                            continue
                        if metadata.is_link(info):
                            self.record(os.path.join(path, entry.name), "linked-skipped")
                        else:
                            result.append((os.path.join(path, entry.name), info))
            record["status"] = "complete-discovery"
        except metadata.BudgetExceeded as error:
            record["status"] = str(error)
            raise
        except metadata.BoundarySkipped as error:
            record["status"] = error.status
        except FileNotFoundError:
            record["status"] = "absent"
        except OSError:
            record["status"] = "inaccessible"
        return sorted(result)

    def exists_metadata(self, path):
        try:
            with metadata.root_scope(os.path.dirname(path), self.check) as parent:
                return parent.metadata(os.path.basename(path))
        except FileNotFoundError:
            return None

    def resolve_workspace(self):
        best, nearest = None, None
        current = self.cwd
        try:
            while current != "/":
                self.check()
                if current != self.home:
                    for marker in MARKERS:
                        if self.exists_metadata(os.path.join(current, marker)) is not None:
                            nearest = nearest or current
                            best = current
                            break
                current = os.path.dirname(current)
        except (OSError, metadata.BudgetExceeded):
            self.warnings.append("workspace-resolution-incomplete")
        root = best or self.cwd
        scoped = root not in (self.home, "/") and "workspace-resolution-incomplete" not in self.warnings
        return {"cwd": self.cwd, "root": root if scoped else None, "scoped": scoped,
                "resolution": "outermost-marker-excluding-home" if best else "cwd-fallback" if scoped else "profile-root-rejected",
                "nearerMarker": nearest if nearest != root else None}

    def add(self, path, category, owner=None, protected=False, **evidence):
        path = absolute(path)
        if path in (self.home, "/") or any(part in ("Documents", "Desktop", "CloudStorage") for part in Path(path).parts):
            self.record(path, "unsafe-or-personal-root-rejected")
            return
        if len(self.targets) >= 5000 and path not in self.targets:
            raise metadata.BudgetExceeded("target-limit")
        value = {"path": path, "category": category, "owner": owner,
                 "protected": protected, "evidence": evidence}
        # Exact known tool/manual/protected scopes outrank generic app-cache labels.
        previous = self.targets.get(path)
        if previous is None or previous["category"] == "app-cache" or protected:
            self.targets[path] = value

    def configured(self, variable, default):
        value = self.env.get(variable, default)
        if value.startswith("~/"):
            value = self.home + value[1:]
        if not value.startswith("/") or any(char in value for char in "\r\n${}"):
            self.warnings.append("configured-cache-path-unresolved")
            return None
        return absolute(value)

    def selector(self, path, releases):
        try:
            with metadata.root_scope(os.path.dirname(path), self.check) as parent:
                info = parent.metadata(os.path.basename(path))
                if stat.S_ISLNK(info.st_mode):
                    value = os.readlink(os.path.basename(path), dir_fd=parent.descriptor)
                    target = absolute(os.path.join(os.path.dirname(path), value))
                    after = parent.metadata(os.path.basename(path))
                    if (info.st_ino, info.st_mtime_ns) != (after.st_ino, after.st_mtime_ns):
                        return None
                    return os.path.basename(target) if os.path.dirname(target) == absolute(releases) else None
            value = read_metadata(path, self.check, 4096).decode().strip()
            return value if re.fullmatch(r"\d+\.\d+\.\d+(?:-(?:aarch64|x86_64|arm64)-[A-Za-z0-9_-]+)?", value) else None
        except (OSError, UnicodeError):
            return None

    def releases(self, root, current_selector, update_selector=None):
        rows = self.children(root)
        names = {os.path.basename(path) for path, _ in rows}
        current = self.selector(current_selector, root)
        update = self.selector(update_selector, root) if update_selector else None
        versions = {}
        for name in names:
            match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(?:aarch64|x86_64|arm64)-[A-Za-z0-9_-]+)?", name)
            if match:
                versions[name] = tuple(map(int, match.groups()))
        newest = max(versions.values(), default=None)
        for path, _ in rows:
            name = os.path.basename(path)
            keep = name in (current, update) or name not in versions or versions.get(name) == newest
            self.add(path, "runtime-release", protected=keep,
                     current=name == current, updateSelected=name == update,
                     newest=name in versions and versions[name] == newest,
                     selectorComplete=current in names, pinOwnership="unknown", updateOwnership="unknown",
                     consequence="Removing a release loses rollback/offline reuse; this inventory never authorizes it.")

    def discover_runtimes(self):
        self.releases(self.path(".local/share/claude/versions"), self.path(".local/bin/claude"))
        for family, info in self.children(self.path(".codex/packages")):
            if stat.S_ISDIR(info.st_mode):
                self.releases(os.path.join(family, "releases"), os.path.join(family, "current"),
                              os.path.join(family, "auto-update-version"))
        for family, info in self.children(self.path(".cache/codex-runtimes")):
            if stat.S_ISDIR(info.st_mode):
                self.add(family, "runtime-cache", protected=True, pinOwnership="unknown")
        stores = {self.path("Library/pnpm/store"), self.path(".local/share/pnpm/store"), self.path(".pnpm-store")}
        if self.env.get("PNPM_HOME"):
            value = self.configured("PNPM_HOME", "")
            if value:
                stores.add(os.path.join(value, "store"))
        for root in stores:
            for path, info in self.children(root):
                if stat.S_ISDIR(info.st_mode):
                    self.add(path, "pnpm-store-generation", pinOwnership="unknown", activeStore="unknown")

    def discover_apps(self):
        for root in self.apps:
            for path, info in self.children(root):
                if not path.endswith(".app") or not stat.S_ISDIR(info.st_mode):
                    continue
                try:
                    data = plistlib.loads(read_metadata(os.path.join(path, "Contents/Info.plist"), self.check))
                    if not isinstance(data, dict):
                        raise ValueError("unsupported-app-metadata")
                    bundle = data.get("CFBundleIdentifier")
                    name = data.get("CFBundleDisplayName", data.get("CFBundleName", Path(path).stem))
                    if isinstance(bundle, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,200}", bundle) and isinstance(name, str):
                        name = "".join(char for char in name[:100] if char.isprintable())
                        self.app_names[bundle] = name
                        self.app_labels.add(name.casefold())
                except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
                    self.record(path, "app-metadata-unavailable")

    def discover_caches(self):
        for path, _ in self.children(self.path("Library/Caches")):
            name = os.path.basename(path)
            owner = self.app_names.get(name)
            alias = APP_ALIASES.get(name)
            if alias and alias.casefold() in self.app_labels:
                owner = alias
            self.add(path, "homebrew-manual" if name == "Homebrew" else "app-cache", owner,
                     name.startswith("com.apple.") or name in ("SiriTTS", "FamilyCircle"))
        for relative, label in SUPPORT.items():
            root = self.path("Library/Application Support/" + relative)
            for profile, info in self.children(root):
                name = os.path.basename(profile)
                if stat.S_ISDIR(info.st_mode) and (name == "Default" or re.fullmatch(r"Profile \d+", name)):
                    for cache in ("Cache", "Code Cache", "GPUCache"):
                        self.add(os.path.join(profile, cache), "browser-cache", label)
            if label == "Opera":
                for cache in ("Cache", "Code Cache", "GPUCache"):
                    self.add(os.path.join(root, cache), "browser-cache", label)
        for relative, label in ELECTRON.items():
            for cache in ("Cache", "Code Cache", "GPUCache", "CachedData"):
                self.add(self.path("Library/Application Support/" + relative + "/" + cache), "app-cache", label)
        for container, info in self.children(self.path("Library/Containers")):
            bundle = os.path.basename(container)
            if stat.S_ISDIR(info.st_mode) and bundle in self.app_names:
                self.add(os.path.join(container, "Data/Library/Caches"), "sandbox-cache", self.app_names[bundle],
                         protected=bundle.startswith("com.apple."))
        # Never walk entire containers, group containers, profiles or VM data.
        self.record(self.path("Library/Group Containers"), "not-inspected-protected")

    def discover_tools(self):
        if not self.tool_probe:
            self.warnings.append("tool-native-metadata-probing-disabled")
        defaults = [("PIP_CACHE_DIR", "Library/Caches/pip", "pip-cache"),
                    ("UV_CACHE_DIR", "Library/Caches/uv", "uv-cache"),
                    ("PUPPETEER_CACHE_DIR", ".cache/puppeteer", "automation-cache"),
                    ("PLAYWRIGHT_BROWSERS_PATH", "Library/Caches/ms-playwright", "automation-cache"),
                    ("BUN_INSTALL_CACHE_DIR", ".bun/install/cache", "bun-cache")]
        for variable, default, category in defaults:
            path = self.configured(variable, self.path(default))
            if path:
                self.add(path, category, source=variable if variable in self.env else "known-default")
        hf_home = self.configured("HF_HOME", self.path(".cache/huggingface"))
        hub = self.configured("HF_HUB_CACHE", os.path.join(hf_home, "hub") if hf_home else "")
        if hub:
            self.add(hub, "model-cache")
        npm = self.env.get("NPM_CONFIG_CACHE", self.env.get("npm_config_cache"))
        if npm is None:
            try:
                text = read_metadata(self.path(".npmrc"), self.check).decode()
                match = re.search(r"(?m)^\s*cache\s*=\s*(.*?)\s*$", text)
                npm = match[1].strip("\"'") if match else self.path(".npm")
            except FileNotFoundError:
                npm = self.path(".npm")
            except (OSError, UnicodeError):
                npm = ""
                self.warnings.append("npm-cache-config-unreadable")
        env = self.env
        try:
            self.env = {**env, "NPM_CONFIG_CACHE": npm}
            npm = self.configured("NPM_CONFIG_CACHE", "")
        finally:
            self.env = env
        if npm:
            self.add(os.path.join(npm, "_cacache"), "npm-cache")
            for path, info in self.children(os.path.join(npm, "_npx")):
                if stat.S_ISDIR(info.st_mode):
                    self.add(path, "npx-entry", ageAndOwnership="refresh-required")
        if self.tool_probe:
            brew = shutil.which("brew", path=self.env.get("PATH", os.defpath))
            if brew:
                self.check()
                try:
                    code, value = self.bounded_command([brew, "--cache"], seconds=3,
                                           env={**self.env, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"})
                    if code or len(value.splitlines()) != 1 or not value.strip().startswith("/"):
                        raise ValueError("homebrew-cache-unresolved")
                    self.add(value.strip(), "homebrew-manual")
                except (OSError, ValueError, TimeoutError, subprocess.SubprocessError):
                    self.warnings.append("homebrew-cache-metadata-unavailable")
        for relative in (".cargo/registry", ".cargo/git/db", "go/pkg/mod", ".gradle/caches", ".m2/repository"):
            self.add(self.path(relative), "dev-tool-cache")
        self.add(self.path(".Trash"), "trash-manual")
        self.add(self.path("Library/Logs/DiagnosticReports"), "crash-reports")

    def discover_workspace(self):
        root = self.workspace["root"]
        if not root:
            return
        record = {"path": root, "status": "complete-discovery", "linkedSkipped": 0, "inaccessibleSkipped": 0}
        self.coverage.append(record)
        try:
            with closing(metadata.directory_entries(root, record, self.check, min(self.max_depth, 8),
                                                    lambda path: os.path.basename(path) in PRUNE)) as entries:
                for parent, name in entries:
                    self.entries += 1
                    try:
                        info = parent.metadata(name)
                    except OSError:
                        record["inaccessibleSkipped"] += 1
                        continue
                    if metadata.is_link(info):
                        record["linkedSkipped"] += 1
                        continue
                    if name in PROJECT_TARGETS:
                        if stat.S_ISDIR(info.st_mode) and not metadata.is_link(info):
                            self.add(os.path.join(parent.path, name), "workspace-dependencies" if name == "node_modules" else "build-cache",
                                     project=self.project_scope(parent.path, root), unfinishedWork="not-inspected-preserved")
                    if name in ("opencode.json", "opencode.jsonc", ".mcp.json"):
                        source = os.path.join(parent.path, name)
                        runtime = "claude" if name == ".mcp.json" else "opencode"
                        base = os.path.dirname(parent.path) if os.path.basename(parent.path) == ".opencode" else parent.path
                        self.sources.add((source, runtime, base))
        except metadata.BoundarySkipped as error:
            record["status"] = error.status
        except metadata.BudgetExceeded as error:
            record["status"] = str(error)
            raise
        except FileNotFoundError:
            record["status"] = "absent"
        except OSError:
            record["status"] = "inaccessible"
        if record.get("depthSkipped") or record["linkedSkipped"] or record["inaccessibleSkipped"]:
            record["status"] = "partial"

    def project_scope(self, path, workspace):
        if path not in self.project_scopes:
            current, selected = path, path
            while within(current, workspace):
                try:
                    if self.exists_metadata(os.path.join(current, ".git")) is not None:
                        selected = current
                        break
                except OSError:
                    self.warnings.append("project-ownership-scope-incomplete")
                    break
                if current == workspace:
                    break
                current = os.path.dirname(current)
            self.project_scopes[path] = selected
        return self.project_scopes[path]

    def config_sources(self):
        config = self.env.get("XDG_CONFIG_HOME", self.path(".config"))
        for directory in (os.path.join(config, "opencode"), self.system_config):
            for name in ("opencode.json", "opencode.jsonc"):
                self.sources.add((os.path.join(directory, name), "opencode", self.cwd))
        claude_config = self.env.get("CLAUDE_CONFIG_DIR", self.home)
        self.sources.add((os.path.join(claude_config, ".claude.json"), "claude", self.cwd))
        current = self.cwd
        while True:
            for name in ("opencode.json", "opencode.jsonc", ".opencode/opencode.json", ".opencode/opencode.jsonc"):
                self.sources.add((os.path.join(current, name), "opencode", current))
            self.sources.add((os.path.join(current, ".mcp.json"), "claude", current))
            if current == "/":
                break
            current = os.path.dirname(current)

    def measure(self, spec):
        path = spec["path"]
        record = {"path": path, "status": "complete", "linkedSkipped": 0, "inaccessibleSkipped": 0}
        logical, allocated, unknown, newest, shared = 0, 0, 0, 0, 0
        filesystem_id, root_device = None, None
        identities = set()
        def include(file_path, info):
            nonlocal logical, allocated, unknown, newest, shared
            newest = max(newest, info.st_mtime)
            if not stat.S_ISREG(info.st_mode) or metadata.is_link(info):
                return
            if info.st_dev != root_device:
                record["crossFilesystemSkipped"] = record.get("crossFilesystemSkipped", 0) + 1
                return
            identity = (info.st_dev, info.st_ino)
            if identity in identities:
                return
            identities.add(identity)
            logical += info.st_size
            value, _ = metadata.allocated_bytes(file_path, info)
            unknown += value is None
            allocated += value or 0
            shared += info.st_nlink > 1
            if identity not in self.global_ids:
                self.global_ids.add(identity)
                self.global_logical += info.st_size
                self.global_allocated += value or 0
                self.global_unknown += value is None
        try:
            with metadata.root_scope(os.path.dirname(path), self.check) as parent:
                info = parent.metadata(os.path.basename(path))
                if metadata.is_link(info):
                    raise metadata.BoundarySkipped("linked-skipped")
                root_device = info.st_dev
                if self.space is not None:
                    filesystem_id = self.space.observe(path if stat.S_ISDIR(info.st_mode) else os.path.dirname(path), root_device)
                newest = info.st_mtime
                if stat.S_ISREG(info.st_mode):
                    include(path, info)
                elif stat.S_ISDIR(info.st_mode):
                    with closing(metadata.directory_entries(path, record, self.check, self.max_depth,
                                                            root_device=root_device)) as entries:
                        for directory, name in entries:
                            self.entries += 1
                            with metadata.file_metadata(directory, name) as (file_path, info):
                                if metadata.is_link(info):
                                    record["linkedSkipped"] += 1
                                include(file_path, info)
                else:
                    record["status"] = "unsupported"
        except metadata.BudgetExceeded as error:
            record["status"] = str(error)
        except metadata.BoundarySkipped as error:
            record["status"] = error.status
        except FileNotFoundError:
            record["status"] = "absent"
        except OSError:
            record["status"] = "inaccessible"
        if record.get("depthSkipped") or record.get("crossFilesystemSkipped") or record["linkedSkipped"] or record["inaccessibleSkipped"]:
            record["status"] = "partial" if record["status"] == "complete" else record["status"]
        self.coverage.append(record)
        complete = record["status"] == "complete"
        owned = spec["category"] in ("workspace-dependencies", "build-cache") and any(
            within(value, spec["evidence"]["project"]) or within(spec["evidence"]["project"], value)
            for value in self.ownership["paths"])
        classification = "human-review"
        if spec["protected"] or owned or live(path, self.process) or (spec["category"] == "model-cache" and self.process["modelHost"]):
            classification = "live-dependency" if owned or live(path, self.process) else "protected"
        elif spec["category"] == "homebrew-manual":
            classification = "manual-only"
        elif spec["owner"]:
            classification = "close-application-first"
        if spec["category"] == "build-cache" and newest > time.time() - 86400:
            classification = "live-dependency"
        return {"path": path, "category": spec["category"], "owner": spec["owner"],
                "classification": classification, "selectable": False, "coverage": record["status"],
                "filesystemId": filesystem_id, "logicalBytes": logical if complete else None,
                "allocatedBytes": allocated if complete and not unknown else None,
                "observedLogicalBytes": logical, "observedAllocatedKnownBytes": allocated,
                "estimatedReclaimableBytes": None, "allocationMethod": "stat-blocks",
                "sharedFiles": shared, "unknownAllocationFiles": unknown,
                "cloneSnapshotSharing": "unknown", "newestWrite": newest if complete else None,
                "evidence": {**spec["evidence"], "registeredMcpOwner": owned},
                "consequence": "Prefer supported in-app cache controls; any exact-path alternative needs fresh independent approval and checks." if spec["owner"] else "Read-only inventory; no deletion authority."}

    def scan(self):
        interrupted = None
        stages = [{"name": name, "status": "not-inspected"} for name in
                  ("processes", "filesystem-baseline", "runtimes", "tools", "applications", "caches", "workspace", "registrations")]
        def baseline():
            if self.space is None:
                self.warnings.append("filesystem-space-probing-disabled")
                return
            for path in dict.fromkeys(("/", self.home, self.workspace["root"] or self.cwd)):
                self.space.observe(path)
        def census():
            if self.process is None:
                self.process = processes(self.bounded_command)
        def registrations():
            self.config_sources()
            self.ownership = mcp_ownership(self.sources, self.cwd, self.home, self.env, self.check)
        try:
            for stage, action in zip(stages, (census, baseline, self.discover_runtimes, self.discover_tools,
                                              self.discover_apps, self.discover_caches, self.discover_workspace, registrations)):
                self.check()
                stage["status"] = "started"
                action()
                stage["status"] = "finished-bounded-stage"
        except metadata.BudgetExceeded as error:
            interrupted = str(error)
            stage["status"] = interrupted
            self.warnings.append("discovery-" + interrupted)
        self.process = self.process or no_processes()
        if not hasattr(self, "ownership"):
            self.ownership = {"paths": set(), "summary": {"status": "partial", "sourcesRead": 0,
                                                           "failures": ["ownership-discovery-incomplete"]}}
        rows = []
        containing_roots = set()
        for path, spec in self.targets.items():
            parent = os.path.dirname(path)
            while parent != "/":
                containing_roots.add(parent)
                ancestor = self.targets.get(parent)
                if ancestor:
                    if ancestor["protected"]:
                        spec["protected"] = True
                        spec["evidence"]["protectedAncestor"] = parent
                    if ancestor["category"] == "homebrew-manual":
                        spec["category"] = "homebrew-manual"
                parent = os.path.dirname(parent)
        ordered = sorted(self.targets.values(), key=lambda item: (item["category"] not in ("runtime-release", "pnpm-store-generation"), item["path"]))
        for spec in ordered:
            # Specific descendants take precedence; broad overlapping cache parents stay unmeasured.
            if spec["path"] in containing_roots:
                self.record(spec["path"], "overlapping-root-not-measured", coveredBy="more-specific-discovery-roots")
                continue
            rows.append(self.measure(spec))
        material = [row for row in rows if (row["logicalBytes"] is None and row["coverage"] != "absent") or
                    max(row["logicalBytes"] or 0, row["allocatedBytes"] or 0) >= self.minimum]
        material.sort(key=lambda row: (-(row["observedAllocatedKnownBytes"] or row["observedLogicalBytes"]), row["path"]))
        partial = (interrupted or self.process["summary"]["status"] != "complete" or
                   self.ownership["summary"]["status"] != "complete-static-sources" or
                   any(row["status"] not in ("complete", "complete-discovery", "absent", "not-inspected-protected") for row in self.coverage))
        return {"schemaVersion": "1.0", "purpose": "read-only-macos-discovery",
                "createdAt": datetime.now(timezone.utc).isoformat(), "platform": platform.system(),
                "workspace": self.workspace, "status": "partial" if partial else "complete-scoped-discovery",
                "limits": {"maxSeconds": self.max_seconds, "maxEntries": self.max_entries,
                           "maxDepth": self.max_depth, "workspaceDepth": min(self.max_depth, 8), "limit": self.limit},
                "entriesVisited": self.entries, "minimumBytes": self.minimum,
                "coverage": self.coverage, "coverageSummary": coverage_summary(self.coverage),
                "workspaceDescentExclusions": sorted(PRUNE),
                "discoveryStages": stages, "processCensus": self.process["summary"],
                "filesystemSpace": self.space.evidence() if self.space else
                    {"filesystems": [], "scopes": [], "sharedContainers": [], "limitations": ["Space probing disabled; filesystem space is unknown."]},
                "registeredMcp": self.ownership["summary"], "warnings": self.warnings,
                "totals": {"observedLogicalBytes": self.global_logical,
                           "observedAllocatedKnownBytes": self.global_allocated,
                           "unknownAllocationFiles": self.global_unknown,
                           "estimatedReclaimableBytes": None},
                "omittedMatches": max(0, len(material) - self.limit), "items": material[:self.limit],
                "belowThresholdTargets": sum(row["coverage"] == "complete" and
                    max(row["logicalBytes"] or 0, row["allocatedBytes"] or 0) < self.minimum for row in rows),
                "limitations": ["Not a full-drive census or cleanup plan; all items are non-selectable evidence.",
                                "No absence of runtime pins/consumers is proved; APFS clone/snapshot sharing is unknown.",
                                "A manually cleared item is user-reported until remeasured; it proves no recovered-byte amount."]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", default=str(Path.home()))
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--applications", action="append")
    parser.add_argument("--system-config-root")
    parser.add_argument("--no-process-probe", action="store_true")
    parser.add_argument("--no-tool-probe", action="store_true")
    parser.add_argument("--no-space-probe", action="store_true", help="Disclose unknown filesystem space; intended for isolated fixtures")
    parser.add_argument("--max-seconds", type=int, default=45)
    parser.add_argument("--max-entries", type=int, default=250000)
    parser.add_argument("--max-depth", type=int, default=20)
    parser.add_argument("--minimum-mib", type=int, default=50)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--output", required=True, help="New private JSON evidence file; never overwritten")
    args = parser.parse_args(argv)
    if sys.version_info < (3, 10):
        parser.error("Existing Python 3.10+ is required; no dependency installation is performed")
    if platform.system() != "Darwin":
        parser.error("This entry point requires macOS; no platform override is accepted")
    if min(args.max_seconds, args.max_entries, args.max_depth, args.minimum_mib, args.limit) <= 0:
        parser.error("Budgets and reporting threshold must be positive")
    scanner = Scanner(args.home, args.cwd, application_roots=args.applications,
                      system_config=args.system_config_root, max_seconds=args.max_seconds,
                      max_entries=args.max_entries, max_depth=args.max_depth, limit=args.limit,
                      minimum_bytes=args.minimum_mib * MIB, process=no_processes() if args.no_process_probe else None,
                      tool_probe=not args.no_tool_probe, space_probe=not args.no_space_probe)
    result = scanner.scan()
    write_private(args.output, result)
    print(json.dumps({"status": result["status"], "purpose": result["purpose"],
                      "items": len(result["items"]), "omittedMatches": result["omittedMatches"]}))


if __name__ == "__main__":
    main()
