#!/bin/bash
set -e

REPO_URL="https://raw.githubusercontent.com/zhiganov/claude-cleanup/master"
CLAUDE_DIR="$HOME/.claude"

echo "Installing claude-cleanup..."

stage="$CLAUDE_DIR/.cleanup-install-$$"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/commands" "$stage/cleanup-scripts" "$stage/cleanup-contracts/schemas" "$stage/cleanup-contracts/policies"
curl -fsSL "$REPO_URL/.claude/commands/cleanup.md" -o "$stage/commands/cleanup.md"

# Windows helper scripts (used by the scan/delete steps under MSYS2/Git Bash).
# The command resolves these from ~/.claude/cleanup-scripts/ when present.
for f in wt_lookup.py find_targets.py assert_list.py live_paths.ps1 diskspace.ps1 run_wiztree.ps1 squirrel.ps1 \
         appdata_orphans.ps1 winsdk.ps1 vs_orphans.ps1 scrub.ps1 scan.ps1 execute-plan.ps1 README.md; do
  curl -fsSL "$REPO_URL/scripts/windows/cleanup/$f" -o "$stage/cleanup-scripts/$f"
done

for f in Cleanup.Contracts.psm1 build-plan.ps1 validate-plan.ps1 render-scan.ps1 README.md \
         schemas/scan.schema.json schemas/plan.schema.json schemas/result.schema.json policies/windows.v1.json; do
  curl -fsSL "$REPO_URL/scripts/cleanup/$f" -o "$stage/cleanup-contracts/$f"
done
curl -fsSL "$REPO_URL/install-manifest.sha256" -o "$stage/cleanup-manifest.sha256"
(cd "$stage" && sha256sum -c --quiet cleanup-manifest.sha256)

# Install the command first and the verified manifest last. If any copy fails,
# the command sees a missing/old manifest and refuses the mixed installation.
[ ! -L "$CLAUDE_DIR/cleanup-scripts" ] || { echo "Refusing to overwrite cleanup-scripts symlink" >&2; exit 1; }
[ ! -L "$CLAUDE_DIR/cleanup-contracts" ] || { echo "Refusing to overwrite cleanup-contracts symlink" >&2; exit 1; }
mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/cleanup-scripts" "$CLAUDE_DIR/cleanup-contracts"
cp "$stage/commands/cleanup.md" "$CLAUDE_DIR/commands/cleanup.md"
cp -R "$stage/cleanup-scripts/." "$CLAUDE_DIR/cleanup-scripts/"
cp -R "$stage/cleanup-contracts/." "$CLAUDE_DIR/cleanup-contracts/"
cp "$stage/cleanup-manifest.sha256" "$CLAUDE_DIR/cleanup-manifest.sha256"
echo "✓ Installed cleanup.md → ~/.claude/commands/"
echo "✓ Installed Windows helper scripts → ~/.claude/cleanup-scripts/"
echo "✓ Installed structured contracts → ~/.claude/cleanup-contracts/"

echo ""
echo "Installation complete! Use /cleanup in Claude Code to get started."
