#!/usr/bin/env python3
"""Maintainer-only normalized release manifest for this repository.

Run from a reviewed implementation branch. Never installs into runtime/user
directories, copies code from other repositories, removes files, updates hooks,
or runs cleanup. --check is read-only.
"""
import argparse
import hashlib
from pathlib import Path


def normalized(path):
    return path.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")


def release_inventory(publication):
    paths = ["cleanup.md", "skills/agentic-cleanup/SKILL.md", "skills/agentic-cleanup/references/workflow.md"]
    for prefix in ("scripts/windows/cleanup", "scripts/cleanup"):
        for file in sorted((publication / prefix).rglob("*")):
            relative = file.relative_to(publication).as_posix()
            if file.is_file() and file.suffix in (".py", ".ps1", ".psm1", ".md", ".json") and not any(
                    part in ("tests", "fixtures", "__pycache__") for part in file.relative_to(publication / prefix).parts):
                if file.name != "update-manifest.py":
                    paths.append(relative)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    publication = Path(__file__).resolve().parents[2]
    if not (publication / "install.ps1").is_file():
        parser.error("Expected the agentic-cleanup repository")
    paths = release_inventory(publication)
    manifest = "".join(f"{hashlib.sha256(normalized(publication / path)).hexdigest()}  {path}\n" for path in paths)
    manifest_path = publication / "install-manifest.sha256"
    manifest_matches = manifest_path.exists() and normalized(manifest_path) == manifest.encode("utf-8")
    if not args.check:
        manifest_path.write_text(manifest, encoding="utf-8", newline="\n")
    if args.check and not manifest_matches:
        print("FAIL: release inventory or manifest hashes do not match this repository")
        return 1
    print(f"OK: release files={len(paths)}, check={args.check}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
