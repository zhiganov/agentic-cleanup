#!/usr/bin/env python3
"""Regression tests for the release manifest's platform-independent order."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path


sys.dont_write_bytecode = True  # don't leave scripts/cleanup/__pycache__ in the repository

REPO_ROOT = Path(__file__).resolve().parents[3]
HELPER_PATH = REPO_ROOT / "scripts" / "cleanup" / "update-manifest.py"
spec = importlib.util.spec_from_file_location("update_manifest", HELPER_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(f"FAIL: {message}")
    print(f"PASS: {message}")


def test_inventory_order_ignores_case() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name in ("cleanup.md", "skills/agentic-cleanup/SKILL.md", "skills/agentic-cleanup/references/workflow.md"):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text("x\n", encoding="utf-8")
        for name in ("scripts/windows/cleanup/README.md", "scripts/windows/cleanup/appdata.ps1",
                     "scripts/cleanup/Cleanup.Contracts.psm1", "scripts/cleanup/build-plan.ps1",
                     "scripts/cleanup/policies/windows.v1.json", "scripts/cleanup/README.md",
                     "scripts/cleanup/tests/ignored.py"):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text("x\n", encoding="utf-8")
        paths = module.release_inventory(root)
        assert_true(paths[3:] == [
            "scripts/windows/cleanup/appdata.ps1",
            "scripts/windows/cleanup/README.md",
            "scripts/cleanup/build-plan.ps1",
            "scripts/cleanup/Cleanup.Contracts.psm1",
            "scripts/cleanup/policies/windows.v1.json",
            "scripts/cleanup/README.md",
        ], "inventory sorts case-insensitively by path part, skipping tests")


def test_committed_manifest_checks_clean() -> None:
    result = subprocess.run([sys.executable, str(HELPER_PATH), "--check"], capture_output=True, text=True)
    assert_true(result.returncode == 0, f"committed manifest passes --check on {sys.platform}: {result.stdout.strip()}")


test_inventory_order_ignores_case()
test_committed_manifest_checks_clean()
