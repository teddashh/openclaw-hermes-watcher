#!/usr/bin/env bash
# 11-tg-hermes.sh — Phase 2: enable Hermes Agent's own Telegram gateway.
#
# Reads TG_BOT_HERMES_AGENT_TOKEN from machine.env. If empty, skips entirely.
#
# Phase 2 is opt-in. Hermes by SOUL contract does NOT push autonomously — the
# gateway is purely for two-way chat (you ask, Hermes answers). Cross-patrol
# alerts use a different bot (configured in 10-tg-maintainer.sh) so they remain
# triggered-by-stale-peer-detection rather than autonomous.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

section "Phase 2 — Hermes Agent's own Telegram gateway"

if [ -z "${TG_BOT_HERMES_AGENT_TOKEN:-}" ]; then
    info "TG_BOT_HERMES_AGENT_TOKEN empty — skipping Phase 2"
    info "  To enable later: paste a token from @BotFather and re-run this script."
    exit 0
fi

emit_journal_event deploy_phase2_started "bot=${TG_BOT_HERMES_AGENT_NAME:-(unnamed)}"

# Hermes has its own gateway install command. Ensure profile-scoped.
PROFILE="openclaw-evolution"

# Set Hermes config: enable Telegram, paste token
info "Configuring Hermes openclaw-evolution profile messaging.telegram..."
hermes -p "$PROFILE" config set messaging.telegram.enabled true --strict-json 2>/dev/null \
    || hermes -p "$PROFILE" config set messaging.telegram.enabled true \
    || die "Failed to enable telegram messaging in Hermes config"

hermes -p "$PROFILE" config set messaging.telegram.bot_token "$TG_BOT_HERMES_AGENT_TOKEN" --strict-json 2>/dev/null \
    || hermes -p "$PROFILE" config set messaging.telegram.bot_token "$TG_BOT_HERMES_AGENT_TOKEN" \
    || die "Failed to set Hermes telegram bot token"

if [ -n "${OPERATOR_TELEGRAM_USER_ID:-}" ]; then
    hermes -p "$PROFILE" config set messaging.telegram.allowed_user_id "$OPERATOR_TELEGRAM_USER_ID" --strict-json 2>/dev/null \
        || hermes -p "$PROFILE" config set messaging.telegram.allowed_user_id "$OPERATOR_TELEGRAM_USER_ID" \
        || warn "Failed to set allowed_user_id; check Hermes config schema"
fi

# Install profile-scoped systemd unit for the gateway
info "Installing hermes-gateway-${PROFILE}.service via 'hermes gateway install'..."
hermes -p "$PROFILE" gateway install --force >/dev/null 2>&1 \
    || die "hermes gateway install failed — check 'hermes gateway --help'"

systemctl --user daemon-reload
systemctl --user enable "hermes-gateway-${PROFILE}.service" >/dev/null 2>&1 || true
# `restart` not `start`: the documented re-run path for token rotation
# (edit machine.env, re-run scripts/11) requires the daemon to pick up the
# new token. `start` is a no-op when already active and the daemon would
# silently keep the old token in memory.
systemctl --user restart "hermes-gateway-${PROFILE}.service" >/dev/null 2>&1 || true
sleep 3

if systemctl --user is-active "hermes-gateway-${PROFILE}.service" >/dev/null 2>&1; then
    ok "hermes-gateway-${PROFILE}.service active"
else
    journalctl --user -u "hermes-gateway-${PROFILE}.service" --no-pager -n 20 2>&1 | sed 's/^/  /' || true
    die "hermes-gateway-${PROFILE}.service failed to start"
fi

emit_journal_event deploy_phase2_completed "bot=${TG_BOT_HERMES_AGENT_NAME:-(unnamed)}"

cat <<EOF

${GREEN}Phase 2 enabled.${NC}

Hermes Agent's openclaw-evolution profile now has its own Telegram gateway.
Try messaging @${TG_BOT_HERMES_AGENT_NAME:-(your-bot)} on Telegram with a
question; Hermes should reply.

Per Hermes's SOUL contract:
  - Hermes does NOT push autonomously.
  - Telegram is for two-way chat: you ask, Hermes answers.
  - Cross-patrol alerts (cron failures) use the maintainer's bot, not this one.
EOF
