#!/usr/bin/env python3
"""Maintainer-only narrow canonical sync and normalized release manifest.

Run from a reviewed implementation branch. Never installs into runtime/user
directories, removes files, updates hooks, or runs cleanup. --check is read-only.
"""
import argparse
import hashlib
from pathlib import Path


def normalized(path):
    return path.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")


def inventory(source):
    pairs = [(source / "commands/cleanup.md", "cleanup.md")]
    for prefix in ("skills/agentic-cleanup", "scripts/windows/cleanup", "scripts/cleanup"):
        for file in sorted((source / prefix).rglob("*")):
            if file.is_file() and file.suffix in (".md", ".py", ".ps1", ".psm1", ".json") and "__pycache__" not in file.parts:
                pairs.append((file, file.relative_to(source).as_posix()))
    return pairs


def release_inventory(publication):
    paths = ["cleanup.md", "skills/agentic-cleanup/SKILL.md", "skills/agentic-cleanup/references/workflow.md"]
    for prefix in ("scripts/windows/cleanup", "scripts/cleanup"):
        for file in sorted((publication / prefix).rglob("*")):
            relative = file.relative_to(publication).as_posix()
            if file.is_file() and file.suffix in (".py", ".ps1", ".psm1", ".md", ".json") and not any(
                    part in ("tests", "fixtures", "__pycache__") for part in file.relative_to(publication / prefix).parts):
                if file.name != "sync-publication.py":
                    paths.append(relative)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Canonical claude-config repository")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve()
    publication = Path(__file__).resolve().parents[2]
    if source == publication or not (source / "commands/cleanup.md").is_file() or not (publication / "install.ps1").is_file():
        parser.error("Expected distinct canonical and publication repositories")
    pairs = inventory(source)
    mismatches = []
    for original, relative in pairs:
        destination = publication / relative
        if not destination.exists() or normalized(original) != normalized(destination):
            mismatches.append(relative)
            if not args.check:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(normalized(original))
    paths = release_inventory(publication)
    manifest = "".join(f"{hashlib.sha256(normalized(publication / path)).hexdigest()}  {path}\n" for path in paths)
    manifest_path = publication / "install-manifest.sha256"
    manifest_matches = manifest_path.exists() and normalized(manifest_path) == manifest.encode("utf-8")
    if not args.check:
        manifest_path.write_text(manifest, encoding="utf-8", newline="\n")
    if args.check and (mismatches or not manifest_matches):
        print(f"FAIL: canonical mismatches={len(mismatches)}, manifest matches={manifest_matches}")
        return 1
    print(f"OK: canonical files={len(pairs)}, changed={len(mismatches)}, release files={len(paths)}, check={args.check}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
