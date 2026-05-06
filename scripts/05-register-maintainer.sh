#!/usr/bin/env bash
# 05-register-maintainer.sh — register the hermes-maintainer OpenClaw subagent.
#
# Pre-bakes AGENTS.md, IDENTITY.md, USER.md, MACHINE_LOG.md, study-notes/README.md
# in the subagent workspace, then `openclaw agents add` to register, then makes
# sure agents.defaults.subagents.allowAgents includes the new agent name.
#
# Idempotent.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

SUBAGENT_NAME="hermes-maintainer"
SUBAGENT_HOME="$HOME/$SUBAGENT_NAME"
SUBAGENT_WS_DIR="$SUBAGENT_HOME/.openclaw-ws"
OUT_DIR="$REPO_ROOT/.render-cache"

section "Register $SUBAGENT_NAME OpenClaw subagent"

command -v openclaw >/dev/null 2>&1 || die "openclaw CLI not found"
[ -f "$OUT_DIR/hermes-maintainer-AGENTS.md" ] || die "Run 01-render.sh first"

emit_journal_event deploy_register_maintainer_started ""

mkdir -p "$SUBAGENT_HOME" "$SUBAGENT_WS_DIR" "$SUBAGENT_WS_DIR/study-notes"

cp "$OUT_DIR/hermes-maintainer-AGENTS.md"   "$SUBAGENT_WS_DIR/AGENTS.md"
cp "$OUT_DIR/hermes-maintainer-IDENTITY.md" "$SUBAGENT_WS_DIR/IDENTITY.md"

if [ ! -f "$SUBAGENT_WS_DIR/USER.md" ]; then
    cat > "$SUBAGENT_WS_DIR/USER.md" <<UEOF
# USER

${OPERATOR_HANDLE} (${OPERATOR_NAME}, ${OPERATOR_EMAIL}), based in ${OPERATOR_LOCATION}.

See ~/.openclaw/workspace/baseline/machine-mission.md for full host context.
UEOF
fi

if [ ! -f "$SUBAGENT_WS_DIR/MACHINE_LOG.md" ]; then
    cat > "$SUBAGENT_WS_DIR/MACHINE_LOG.md" <<MLOG_EOF
# MACHINE_LOG — hermes-maintainer

Subagent registered at $(date -u +%Y-%m-%dT%H:%M:%SZ).

## Format

One entry per significant action, dated, terse.

\`\`\`
2026-MM-DD HH:MM Z  action: short description
\`\`\`

## Entries

$(date -u +%Y-%m-%d\ %H:%M)  init: workspace created during deployment
MLOG_EOF
fi

if [ ! -f "$SUBAGENT_WS_DIR/study-notes/README.md" ]; then
    cat > "$SUBAGENT_WS_DIR/study-notes/README.md" <<RMD_EOF
# study-notes

This directory holds focused, dated notes that hermes-maintainer writes for:
- future ${OPERATOR_HANDLE} skimming "what did we conclude about X?"
- future Claude Code rescue "what was Hermes thinking last week?"
- Hermes itself when it asks "what did the maintainer note about my last upgrade?"

Naming: \`YYYY-MM-DD-{topic}.md\`. Keep them small and focused.
RMD_EOF
fi

ok "bootstrap files placed in $SUBAGENT_WS_DIR"

# Already registered?
ALREADY_REGISTERED=false
if openclaw agents list --json 2>/dev/null | jq -e --arg n "$SUBAGENT_NAME" \
        '(.agents // []) | map(.id // .name) | index($n)' >/dev/null 2>&1; then
    ALREADY_REGISTERED=true
elif openclaw agents list 2>/dev/null | grep -qE "^- ${SUBAGENT_NAME}\b"; then
    ALREADY_REGISTERED=true
fi

if $ALREADY_REGISTERED; then
    info "Subagent '$SUBAGENT_NAME' already registered — skipping 'agents add'"
else
    info "Registering '$SUBAGENT_NAME' with OpenClaw..."
    openclaw agents add "$SUBAGENT_NAME" \
        --non-interactive \
        --workspace "$SUBAGENT_WS_DIR" \
        || die "openclaw agents add failed"
    ok "subagent registered"
fi

# Update allowAgents
info "Ensuring allowAgents includes $SUBAGENT_NAME..."
current_list=$(openclaw config get agents.defaults.subagents.allowAgents --json 2>/dev/null || echo '[]')
if ! echo "$current_list" | jq -e 'type == "array"' >/dev/null 2>&1; then
    current_list='[]'
fi

if echo "$current_list" | jq -e --arg s "$SUBAGENT_NAME" 'index($s)' >/dev/null 2>&1; then
    ok "$SUBAGENT_NAME already in allowAgents"
else
    new_list=$(echo "$current_list" | jq -c --arg s "$SUBAGENT_NAME" '. + [$s] | unique')
    info "Updating allowAgents: $current_list -> $new_list"
    openclaw config set agents.defaults.subagents.allowAgents "$new_list" --strict-json --replace \
        || openclaw config set agents.defaults.subagents.allowAgents "$new_list" --strict-json \
        || die "could not update allowAgents"
    ok "allowAgents updated"
fi

# Restart gateway
info "Restarting openclaw-gateway..."
systemctl --user restart openclaw-gateway
sleep 5
systemctl --user is-active openclaw-gateway >/dev/null 2>&1 || \
    die "gateway failed to restart — check journalctl --user -u openclaw-gateway"
ok "gateway restarted"

emit_journal_event deploy_register_maintainer_completed "$SUBAGENT_NAME workspace=$SUBAGENT_WS_DIR"
ok "Step 05 complete. Proceed to 06-cron-setup.sh."
