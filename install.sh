#!/bin/bash
set -euo pipefail

REPO_URL="${AGENTIC_CLEANUP_REPO_URL:-https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DATA_DIR="${AGENTIC_CLEANUP_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agentic-cleanup}"
RUNTIME="${AGENTIC_CLEANUP_RUNTIME:-all}"

case "$RUNTIME" in
  all) install_claude=1; install_opencode=1 ;;
  claude) install_claude=1; install_opencode=0 ;;
  opencode) install_claude=0; install_opencode=1 ;;
  *) echo "Invalid AGENTIC_CLEANUP_RUNTIME: $RUNTIME (expected all, claude, or opencode)" >&2; exit 1 ;;
esac

echo "Installing agentic-cleanup..."

stage="$(mktemp -d "${TMPDIR:-/tmp}/agentic-cleanup-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/scripts/windows/cleanup" "$stage/scripts/cleanup/schemas" "$stage/scripts/cleanup/policies"
curl -fsSL "$REPO_URL/cleanup.md" -o "$stage/cleanup.md"

windows_files=(wt_lookup.py find_targets.py assert_list.py live_paths.ps1 registered_mcp.ps1 diskspace.ps1 run_wiztree.ps1 squirrel.ps1 \
  appdata_orphans.ps1 winsdk.ps1 vs_orphans.ps1 scrub.ps1 scan.ps1 execute-plan.ps1 README.md)
contract_files=(Cleanup.Contracts.psm1 build-plan.ps1 validate-plan.ps1 render-scan.ps1 README.md \
  schemas/scan.schema.json schemas/plan.schema.json schemas/result.schema.json policies/windows.v1.json)

for f in "${windows_files[@]}"; do
  curl -fsSL "$REPO_URL/scripts/windows/cleanup/$f" -o "$stage/scripts/windows/cleanup/$f"
done

for f in "${contract_files[@]}"; do
  curl -fsSL "$REPO_URL/scripts/cleanup/$f" -o "$stage/scripts/cleanup/$f"
done
curl -fsSL "$REPO_URL/install-manifest.sha256" -o "$stage/install-manifest.sha256"

expected_paths=(cleanup.md)
for f in "${windows_files[@]}"; do expected_paths+=("scripts/windows/cleanup/$f"); done
for f in "${contract_files[@]}"; do expected_paths+=("scripts/cleanup/$f"); done
[ "$(wc -l < "$stage/install-manifest.sha256" | tr -d ' ')" -eq "${#expected_paths[@]}" ] || {
  echo "Cleanup install manifest inventory is incomplete" >&2
  exit 1
}
for path in "${expected_paths[@]}"; do
  [ "$(awk -v path="$path" '$2 == path { n++ } END { print n + 0 }' "$stage/install-manifest.sha256")" -eq 1 ] || {
    echo "Cleanup install manifest inventory is invalid: $path" >&2
    exit 1
  }
done
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$stage" && sha256sum -c --quiet install-manifest.sha256)
elif command -v shasum >/dev/null 2>&1; then
  (cd "$stage" && shasum -a 256 -c install-manifest.sha256 >/dev/null)
else
  echo "No SHA-256 verification tool found (sha256sum or shasum required)" >&2
  exit 1
fi

# Publish the manifest last so an interrupted update fails closed.
for target in "$DATA_DIR" "$DATA_DIR/cleanup.md" "$DATA_DIR/install-manifest.sha256" "$DATA_DIR/installed-runtimes" \
              "$DATA_DIR/scripts" "$DATA_DIR/scripts/windows" "$DATA_DIR/scripts/windows/cleanup" \
              "$DATA_DIR/scripts/cleanup" "$DATA_DIR/scripts/cleanup/schemas" "$DATA_DIR/scripts/cleanup/policies" \
              "$CLAUDE_DIR/commands/cleanup.md" "$OPENCODE_DIR/commands/cleanup.md"; do
  [ ! -L "$target" ] || { echo "Refusing to overwrite symlink: $target" >&2; exit 1; }
done
if [ "$install_claude" -eq 1 ]; then
  for target in "$CLAUDE_DIR" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/commands/cleanup.md"; do
    [ ! -L "$target" ] || { echo "Refusing to overwrite symlink: $target" >&2; exit 1; }
  done
fi
if [ "$install_opencode" -eq 1 ]; then
  for target in "$OPENCODE_DIR" "$OPENCODE_DIR/commands" "$OPENCODE_DIR/commands/cleanup.md"; do
    [ ! -L "$target" ] || { echo "Refusing to overwrite symlink: $target" >&2; exit 1; }
  done
fi

if [ "$install_claude" -eq 0 ] && [ -e "$CLAUDE_DIR/commands/cleanup.md" ] && \
   ! cmp -s "$stage/cleanup.md" "$CLAUDE_DIR/commands/cleanup.md"; then
  echo "Refusing to leave a stale Claude Code command: $CLAUDE_DIR/commands/cleanup.md. Install all runtimes or remove that command first." >&2
  exit 1
fi
if [ "$install_opencode" -eq 0 ] && [ -e "$OPENCODE_DIR/commands/cleanup.md" ] && \
   ! cmp -s "$stage/cleanup.md" "$OPENCODE_DIR/commands/cleanup.md"; then
  echo "Refusing to leave a stale OpenCode command: $OPENCODE_DIR/commands/cleanup.md. Install all runtimes or remove that command first." >&2
  exit 1
fi

mkdir -p "$DATA_DIR/scripts/windows/cleanup" "$DATA_DIR/scripts/cleanup"
cp "$stage/cleanup.md" "$DATA_DIR/cleanup.md"
cp -R "$stage/scripts/windows/cleanup/." "$DATA_DIR/scripts/windows/cleanup/"
cp -R "$stage/scripts/cleanup/." "$DATA_DIR/scripts/cleanup/"
if [ "$install_claude" -eq 1 ]; then
  mkdir -p "$CLAUDE_DIR/commands"
  cp "$stage/cleanup.md" "$CLAUDE_DIR/commands/cleanup.md"
  cmp -s "$DATA_DIR/cleanup.md" "$CLAUDE_DIR/commands/cleanup.md"
  echo "Installed /cleanup for Claude Code -> $CLAUDE_DIR/commands/cleanup.md"
fi
if [ "$install_opencode" -eq 1 ]; then
  mkdir -p "$OPENCODE_DIR/commands"
  cp "$stage/cleanup.md" "$OPENCODE_DIR/commands/cleanup.md"
  cmp -s "$DATA_DIR/cleanup.md" "$OPENCODE_DIR/commands/cleanup.md"
  echo "Installed /cleanup for OpenCode V2 -> $OPENCODE_DIR/commands/cleanup.md"
fi
rm -f "$DATA_DIR/installed-runtimes"
cp "$stage/install-manifest.sha256" "$DATA_DIR/install-manifest.sha256"

echo "Installed verified shared payload -> $DATA_DIR"
