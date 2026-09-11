#!/usr/bin/env python3
"""Static safety contract for fixed categories promoted from outlier audits."""

from pathlib import Path


repo_root = Path(__file__).resolve().parents[3]
skill = (repo_root / "skills" / "agentic-cleanup" / "SKILL.md").read_text(encoding="utf-8")


def require(text: str, message: str) -> None:
    if text not in skill:
        raise AssertionError(f"FAIL: {message}")
    print(f"PASS: {message}")


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
require("Keep that exact directory and also keep the newest", "Claude binary cleanup preserves current and newest versions")
require("newest descendant write is older than 7 days", "Stale npx entries have an age floor")
require("canonical parent is exactly `_npx`", "Stale npx cleanup validates its exact parent")
require("immediately before deletion, apply the live-path veto", "Stale npx cleanup refreshes liveness")
require("Treat every other `_npx` byte as protected", "Non-eligible npx content is excluded from reclaim estimates")
require("Never show `hiberfil.sys` as an opportunity", "Hibernation remains excluded from reports")

print("All promoted fixed-category safety checks passed.")
