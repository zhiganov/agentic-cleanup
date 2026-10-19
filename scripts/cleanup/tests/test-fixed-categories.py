#!/usr/bin/env python3
"""Static safety contract for fixed categories promoted from outlier audits."""

from pathlib import Path


repo_root = Path(__file__).resolve().parents[3]
entry_point = (repo_root / "skills" / "agentic-cleanup" / "SKILL.md").read_text(encoding="utf-8")
workflow = (repo_root / "skills" / "agentic-cleanup" / "references" / "workflow.md").read_text(encoding="utf-8")
skill = entry_point + workflow


def require(text: str, message: str) -> None:
    if text not in skill:
        raise AssertionError(f"FAIL: {message}")
    print(f"PASS: {message}")


def require_in(document: str, text: str, message: str) -> None:
    if text not in " ".join(document.split()):
        raise AssertionError(f"FAIL: {message}")
    print(f"PASS: {message}")


require_in(entry_point, "before the first report", "Runtime and store discovery is required before the initial report")
require_in(entry_point, "every generation under each discovered store root", "Initial discovery cannot stop at the active store")
require_in(entry_point, "not follow-up work gated on the user questioning the result", "The initial scan owns runtime/store discovery")
require_in(entry_point, "narrow personal audits and `--structured-preview` keep their declared scope", "The discovery gate does not broaden narrow audits or structured previews")

inventory_heading = "### First-scan runtime and cache inventory"
if inventory_heading not in workflow:
    raise AssertionError("FAIL: Maintained first-scan inventory recipe exists")
inventory = workflow.split(inventory_heading, 1)[1].split("### Cross-platform categories", 1)[0]
require_in(inventory, "~/.codex/packages/<family>/releases", "Codex release families have a bounded discovery path")
require_in(inventory, "current, newest, pinned and live versions", "Runtime discovery preserves all protected version classes")
require_in(inventory, "selector metadata without traversing aliases", "Current-version junctions cannot expand the scan")
require_in(inventory, "installer/update lock", "Runtime candidates require updater-state checks")
require_in(inventory, "file identities and hardlink counts", "Runtime/store accounting checks actual file sharing")
require_in(inventory, "human-review, not a cleanup option", "Ambiguous ownership fails closed without hiding the finding")
require_in(inventory, "Expanded audit", "New runtime scopes remain separately selectable rather than joining all")
require_in(inventory, "not included in `all`", "Runtime audit findings do not broaden blanket category selection")

pnpm = workflow.split("**pnpm:**", 1)[1].split("**yarn:**", 1)[0]
require_in(pnpm, "every immediate versioned store", "pnpm inventory includes legacy store generations")
require_in(pnpm, "does not establish that a sibling generation is unused", "An active-store mismatch is not proof of orphanhood")
require_in(pnpm, "does not clean a legacy sibling", "Current pnpm prune cannot be credited with cleaning an older generation")
require_in(pnpm, "contents only", "Approved legacy-store cleanup retains the store root")
require_in(pnpm, "re-download", "Legacy-store cleanup discloses the cache-miss consequence")

require("#### Category: Browser Automation Downloads", "Playwright and Puppeteer have a maintained category")
require("~/.cache/puppeteer", "Puppeteer uses its exact cache root")
require("protect the entire root", "Browser automation cleanup has a live-descendant veto")
require("%APPDATA%\\Zoom\\data\\WebviewCacheX64", "Zoom WebView uses its exact cache root")
require("Never broaden this target", "Zoom cleanup cannot expand to profile data")
require("confirms Zoom is closed", "Zoom cleanup requires a refreshed closed-process check")
require("#### Category: Downloaded Model Caches", "Hugging Face models have a maintained category")
require("never broaden the target to `~/.cache`", "Model cleanup cannot expand to sibling caches")
require("exclude the probe's own process", "Model-process detection cannot self-match the scanner")
require("basename\n  starts with `mcp-logs-`", "Claude diagnostics match only MCP log directories")
require_in(workflow, "Keep that exact entry and also keep the newest", "Claude binary cleanup preserves current and newest versions")
require_in(workflow, "matching version entry (file or directory)", "Claude binary discovery supports file-based runtime releases")
require("newest descendant write is older than 7 days", "Stale npx entries have an age floor")
require("canonical parent is exactly `_npx`", "Stale npx cleanup validates its exact parent")
require("immediately before deletion, apply the live-path veto", "Stale npx cleanup refreshes liveness")
require("Treat every other `_npx` byte as protected", "Non-eligible npx content is excluded from reclaim estimates")
require("Never show `hiberfil.sys` as an opportunity", "Hibernation remains excluded from reports")

print("All promoted fixed-category safety checks passed.")
