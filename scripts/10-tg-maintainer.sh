#!/usr/bin/env bash
# 10-tg-maintainer.sh — Phase 1.5: bind a Telegram bot to hermes-maintainer.
#
# Reads TG_BOT_HERMES_MAINTAINER_TOKEN from machine.env. If empty, skips this
# phase entirely (Phase 1.5 is opt-in).
#
# Once enabled, you can chat with hermes-maintainer via Telegram on the bot
# whose token is in machine.env. The first time you message the bot, OpenClaw
# will issue a pairing code which you confirm via the bot back to grant your
# Telegram user ID write/read scope on this OpenClaw deployment.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

section "Phase 1.5 — Telegram bot for hermes-maintainer"

if [ -z "${TG_BOT_HERMES_MAINTAINER_TOKEN:-}" ]; then
    info "TG_BOT_HERMES_MAINTAINER_TOKEN empty in machine.env — skipping Phase 1.5"
    info "  To enable later: paste a token from @BotFather and re-run this script."
    exit 0
fi

if [ -z "${TG_BOT_HERMES_MAINTAINER_NAME:-}" ]; then
    warn "TG_BOT_HERMES_MAINTAINER_NAME empty (the @username); proceeding with token only"
fi

emit_journal_event deploy_phase15_started "bot=${TG_BOT_HERMES_MAINTAINER_NAME:-(unnamed)}"

# Configure OpenClaw's Telegram gateway with this bot, bound to hermes-maintainer.
# OpenClaw stores bot tokens in ~/.openclaw/openclaw.json under a per-bot section.
# The exact CLI varies across OpenClaw versions; we try the common forms.

info "Configuring Telegram bot for hermes-maintainer..."
# Real OpenClaw schema (verified against v2026.5.x) is:
#   channels.telegram.accounts.<agent>.botToken
# (NOT gateway.telegram.bots.<agent>.token, which was a guess in earlier
# versions of this script.)
#
# Idempotent: if the bot is already configured (e.g., we re-ran scripts/all.sh
# on a host where bot is already paired and working), `config set` of the
# same value is a no-op. We don't want to error out on "bot already there".
if openclaw config get "channels.telegram.accounts.hermes-maintainer.botToken" >/dev/null 2>&1; then
    EXISTING_TOKEN=$(openclaw config get "channels.telegram.accounts.hermes-maintainer.botToken" 2>/dev/null | tr -d '"')
    if [ "$EXISTING_TOKEN" = "$TG_BOT_HERMES_MAINTAINER_TOKEN" ]; then
        info "  bot already configured with this token — idempotent skip"
    else
        openclaw config set "channels.telegram.accounts.hermes-maintainer.botToken" "$TG_BOT_HERMES_MAINTAINER_TOKEN" >/dev/null \
            || die "Could not update existing bot token; inspect with: openclaw config get channels.telegram.accounts.hermes-maintainer"
        ok "  bot token updated (was different from machine.env.secrets value)"
    fi
elif openclaw config set "channels.telegram.accounts.hermes-maintainer.botToken" "$TG_BOT_HERMES_MAINTAINER_TOKEN" >/dev/null 2>&1; then
    openclaw config set "channels.telegram.accounts.hermes-maintainer.proxy" "${HEARTBEAT_PATROL_PROXY:-http://127.0.0.1:8118}" >/dev/null 2>&1 || true
    ok "  bot added under channels.telegram.accounts.hermes-maintainer"
else
    die "Could not add Telegram bot — check 'openclaw config --help' on your OpenClaw version"
fi

info "Restarting openclaw-gateway to pick up bot..."
systemctl --user restart openclaw-gateway
sleep 5
systemctl --user is-active openclaw-gateway >/dev/null 2>&1 || \
    die "gateway failed to restart"

ok "openclaw-gateway active"

emit_journal_event deploy_phase15_completed "bot=${TG_BOT_HERMES_MAINTAINER_NAME:-(unnamed)}"

cat <<EOF

${GREEN}Phase 1.5 enabled.${NC}

Next step (manual): message your bot @${TG_BOT_HERMES_MAINTAINER_NAME:-(see machine.env)} on Telegram.
OpenClaw will reply with a pairing code; reply with the code to authorize your
Telegram user ID (${OPERATOR_TELEGRAM_USER_ID:-empty}) for read/write/admin/pairing scopes.

After pairing, you can chat with hermes-maintainer via Telegram.
EOF
