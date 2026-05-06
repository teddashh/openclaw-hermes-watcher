#!/usr/bin/env bash
# 01-render.sh — render templates/* using config/machine.env values.
#
# Output goes to a working dir under .render-cache/ in the repo, NOT directly
# to ~/.openclaw/workspace/baseline/. The next script (02-deploy-baseline.sh)
# copies the rendered files there with chattr +i etc.
#
# Idempotent: regenerates every time, fast.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/render-template.sh
source "$SCRIPT_DIR/lib/render-template.sh"

load_config

section "Render templates from $CONFIG_FILE"

OUT_DIR="$REPO_ROOT/.render-cache"
mkdir -p "$OUT_DIR"

render_one() {
    local tmpl="$1" basename="$2"
    info "  $basename"
    render_template "$tmpl" "$OUT_DIR/$basename"
}

# Baseline files (these go to ~/.openclaw/workspace/baseline/)
render_one "$REPO_ROOT/templates/machine-mission.md.tmpl"        machine-mission.md
render_one "$REPO_ROOT/templates/baseline.policy.yaml.tmpl"      baseline.policy.yaml
render_one "$REPO_ROOT/templates/hermes-permissions.yaml.tmpl"   hermes-permissions.yaml

# Generic — copy as-is (no substitution needed)
cp "$REPO_ROOT/lib/watcher.sh" "$OUT_DIR/watcher.sh"

# Systemd unit — uses __HOME__ placeholder; render here
sed "s|__HOME__|$HOME|g; s|__MACHINE_NAME__|$MACHINE_NAME|g" \
    "$REPO_ROOT/templates/openclaw-watcher.service.tmpl" \
    > "$OUT_DIR/openclaw-watcher.service"

# Hermes profile bootstrap files
render_one "$REPO_ROOT/templates/SOUL.md.tmpl"     SOUL.md
render_one "$REPO_ROOT/templates/USER.md.tmpl"     USER.md
render_one "$REPO_ROOT/templates/MEMORY.md.tmpl"   MEMORY.md

# Maintainer subagent bootstrap
render_one "$REPO_ROOT/templates/hermes-maintainer-AGENTS.md.tmpl"   hermes-maintainer-AGENTS.md
render_one "$REPO_ROOT/templates/hermes-maintainer-IDENTITY.md.tmpl" hermes-maintainer-IDENTITY.md

# Hermes daily-study cron prompt
render_one "$REPO_ROOT/templates/hermes-daily-study-prompt.txt.tmpl" hermes-daily-study-prompt.txt

ok "Rendered $(find "$OUT_DIR" -maxdepth 1 -type f | wc -l) files to $OUT_DIR"
ok "Proceed to 02-deploy-baseline.sh."
