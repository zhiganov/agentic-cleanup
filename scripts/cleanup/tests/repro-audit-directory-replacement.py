#!/usr/bin/env python3
"""Read-only-audit race reproduction; mutations affect synthetic fixtures only.

Exit zero requires a replacement attempt and no outside metadata. Print only
allowlisted booleans/counts. No workstation paths or personal data are inspected.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "windows/cleanup"))
import file_audit

with tempfile.TemporaryDirectory(prefix="cleanup-audit-race-") as temp:
    root = Path(temp)
    selected, retained, outside = root / "selected", root / "retained", root / "outside"
    selected.mkdir()
    outside.mkdir()
    (outside / "outside-sentinel.bin").write_bytes(b"fixture")
    real_scandir = file_audit.DirectoryScope.scandir
    replaced = False
    attempted = False
    replacement_blocked = False
    def replace_before_scandir(scope):
        global replaced, attempted, replacement_blocked
        if Path(scope.path) == selected and not attempted:
            attempted = True
            try:
                selected.rename(retained)
            except OSError:
                replacement_blocked = True
            else:
                if os.name == "nt":
                    subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(selected), str(outside)],
                                   check=True, capture_output=True)
                else:
                    selected.symlink_to(outside, target_is_directory=True)
                replaced = True
        return real_scandir(scope)
    try:
        with patch.object(file_audit.DirectoryScope, "scandir", replace_before_scandir):
            report = file_audit.audit([str(selected)], minimum_bytes=1, measure=lambda p, s: (None, "fixture"))
        leaked = any(Path(row["path"]).name == "outside-sentinel.bin" for row in report["files"])
        print(json.dumps({"replacementAttempted": attempted, "replacementBlocked": replacement_blocked,
                          "outsideMetadataReported": leaked, "matchingFiles": report["totals"]["matchingFiles"]}))
        if not attempted or leaked:
            raise AssertionError("Audit scope boundary failed")
    finally:
        if replaced:
            if os.name == "nt":
                subprocess.run(["cmd.exe", "/d", "/c", "rmdir", str(selected)], check=True, capture_output=True)
            else:
                selected.unlink()
