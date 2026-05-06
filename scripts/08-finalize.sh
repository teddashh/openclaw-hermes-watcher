#!/usr/bin/env bash
# 08-finalize.sh — emit a "deploy_finalized" journal event and print a
# friendly summary of the install state.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

section "Finalize"

emit_journal_event deploy_finalized "machine=$MACHINE_NAME operator=$OPERATOR_HANDLE"

cat <<EOF
${GREEN}=== openclaw-hermes-watcher install complete ===${NC}

Machine:     $MACHINE_NAME
Operator:    $OPERATOR_HANDLE ($OPERATOR_NAME)
OpenClaw:    $(openclaw --version 2>/dev/null | head -1)
Hermes:      $(hermes --version 2>/dev/null | head -1)

Cron jobs scheduled:
  - hermes_daily_doctor       $CRON_DAILY_DOCTOR $TZ_NAME
  - hermes_upstream_watch     $CRON_UPSTREAM_WATCH $TZ_NAME
  - hermes_weekly_review      $CRON_WEEKLY_REVIEW $TZ_NAME
  - hermes_monthly_compress   $CRON_MONTHLY_COMPRESS $TZ_NAME
  - openclaw-daily-study      $CRON_HERMES_DAILY_STUDY_UTC UTC (Hermes-side)

Cross-patrol heartbeat:
  - bot:    ${HEARTBEAT_PATROL_BOT_TOKEN:+(configured)}${HEARTBEAT_PATROL_BOT_TOKEN:-(NOT configured — alerts log to file only)}
  - chat:   ${HEARTBEAT_PATROL_CHAT_ID:-(none)}

Next steps:
  - bash scripts/09-talk-helpers.sh       # talk-* ACP shortcuts
  - bash scripts/10-tg-maintainer.sh      # Phase 1.5 — maintainer's Telegram bot
  - bash scripts/11-tg-hermes.sh          # Phase 2 — Hermes Agent's Telegram bot

To verify health any time:
  systemctl --user status openclaw-watcher openclaw-gateway
  openclaw cron list
  hermes -p openclaw-evolution cron list
  tail ~/.openclaw/workspace/evolution-journal.jsonl | jq -c .
  tail ~/.openclaw/workspace/heartbeats/_alerts.log    # patrol alerts (if any)

Documentation:
  README.md / ARCHITECTURE.md / docs/
EOF
