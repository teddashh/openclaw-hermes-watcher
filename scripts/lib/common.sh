#!/usr/bin/env bash
# common.sh — shared helpers for openclaw-hermes-watcher install scripts.
# Source this from each script's preamble.

# Color codes for terminal output (no-op if non-TTY).
if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
fi

ok()    { echo "${GREEN}[OK]${NC} $*"; }
info()  { echo "[..] $*"; }
warn()  { echo "${YELLOW}[WARN]${NC} $*"; }
die()   { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }
section() { echo; echo "${BLUE}==>${NC} $*"; }

# REPO_ROOT — discovered from the script that sourced us. Caller should set
# SCRIPT_DIR before sourcing if they want to override.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config/machine.env}"
SECRETS_FILE="${SECRETS_FILE:-$REPO_ROOT/config/machine.env.secrets}"

# Standard host paths the install creates.
JOURNAL="${JOURNAL:-$HOME/.openclaw/workspace/evolution-journal.jsonl}"
BASELINE_DIR="${BASELINE_DIR:-$HOME/.openclaw/workspace/baseline}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

# load_config: source config/machine.env (non-secret), then optionally
# config/machine.env.secrets (bot tokens — gitignored, may not exist).
# Errors out if the non-secret file is missing.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        die "Missing $CONFIG_FILE — run: cp config/machine.env.example config/machine.env && \$EDITOR config/machine.env"
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # Source secrets if present. The file is gitignored; on first install or
    # on a fresh clone the user has not yet created it. Scripts that genuinely
    # need a token should check for empty after this; install scripts that
    # gate on bot presence (10-tg-maintainer.sh, 11-tg-hermes.sh) already do.
    if [ -f "$SECRETS_FILE" ]; then
        # shellcheck disable=SC1090
        source "$SECRETS_FILE"
    fi

    # Sanity check the absolute minimum
    [ -n "${OPERATOR_NAME:-}" ]  || die "OPERATOR_NAME not set in $CONFIG_FILE"
    [ -n "${OPERATOR_HANDLE:-}" ] || die "OPERATOR_HANDLE not set in $CONFIG_FILE"
    [ -n "${MACHINE_NAME:-}" ]   || die "MACHINE_NAME not set in $CONFIG_FILE"

    # Default empty-ish values
    : "${OPERATOR_LOCATION:=unspecified}"
    : "${OPERATOR_LANGUAGES:=English}"
    : "${OPERATOR_EMAIL:=unspecified}"
    : "${MACHINE_OS:=$(uname -srm 2>/dev/null || echo unknown)}"
    : "${MACHINE_ROLE:=A host running OpenClaw with the openclaw-evolution Hermes profile.}"
    : "${MACHINE_SERVICES_MD:=- (no services declared)}"
    : "${MACHINE_OUT_OF_SCOPE_MD:=- (no out-of-scope items declared)}"
    : "${HERMES_READ_EXTRA_PATHS_MD:=}"

    # Hermes installer ref (used by 03-install-hermes.sh)
    : "${HERMES_INSTALL_REF:=main}"

    # Schedule defaults
    : "${TZ_NAME:=America/New_York}"
    : "${CRON_DAILY_DOCTOR:=30 4 * * *}"
    : "${CRON_UPSTREAM_WATCH:=0 5 * * *}"
    : "${CRON_WEEKLY_REVIEW:=0 5 * * 1}"
    : "${CRON_MONTHLY_COMPRESS:=30 5 1 * *}"
    : "${CRON_HERMES_DAILY_STUDY_UTC:=0 10 * * *}"

    # Telegram bots — empty by default, scripts skip phases without tokens
    : "${TG_BOT_MAIN_TOKEN:=}"
    : "${TG_BOT_MAIN_NAME:=}"
    : "${TG_BOT_HERMES_MAINTAINER_TOKEN:=}"
    : "${TG_BOT_HERMES_MAINTAINER_NAME:=}"
    : "${TG_BOT_HERMES_AGENT_TOKEN:=}"
    : "${TG_BOT_HERMES_AGENT_NAME:=}"
    : "${TG_BOT_PROJECT_SUBAGENT_NAMES:=}"
    : "${TG_BOT_PROJECT_SUBAGENT_TOKENS:=}"
    : "${TG_BOT_PROJECT_SUBAGENT_BOTS:=}"

    : "${HEARTBEAT_PATROL_BOT_TOKEN:=${TG_BOT_HERMES_MAINTAINER_TOKEN:-${TG_BOT_MAIN_TOKEN}}}"
    : "${HEARTBEAT_PATROL_CHAT_ID:=${OPERATOR_TELEGRAM_USER_ID:-}}"
    : "${HEARTBEAT_PATROL_PROXY:=http://127.0.0.1:8118}"

    # Auto-detect known-good versions if blank
    if [ -z "${KNOWN_GOOD_OPENCLAW_VERSION:-}" ]; then
        KNOWN_GOOD_OPENCLAW_VERSION=$(openclaw --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo unknown)
    fi
    if [ -z "${KNOWN_GOOD_HERMES_VERSION:-}" ]; then
        KNOWN_GOOD_HERMES_VERSION=$(hermes --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo unknown)
    fi
    if [ -z "${KNOWN_GOOD_NODE_VERSION:-}" ]; then
        KNOWN_GOOD_NODE_VERSION=$(node --version 2>/dev/null | sed 's/^v//;s/\..*//' || echo unknown)
    fi
    if [ -z "${KNOWN_GOOD_PYTHON_VERSION:-}" ]; then
        KNOWN_GOOD_PYTHON_VERSION=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo unknown)
    fi

    export OPERATOR_NAME OPERATOR_EMAIL OPERATOR_HANDLE OPERATOR_LOCATION OPERATOR_LANGUAGES OPERATOR_TELEGRAM_USER_ID
    export MACHINE_NAME MACHINE_OS MACHINE_ROLE MACHINE_SERVICES_MD MACHINE_OUT_OF_SCOPE_MD HERMES_READ_EXTRA_PATHS_MD
    export TG_BOT_MAIN_TOKEN TG_BOT_MAIN_NAME
    export TG_BOT_HERMES_MAINTAINER_TOKEN TG_BOT_HERMES_MAINTAINER_NAME
    export TG_BOT_HERMES_AGENT_TOKEN TG_BOT_HERMES_AGENT_NAME
    export TG_BOT_PROJECT_SUBAGENT_NAMES TG_BOT_PROJECT_SUBAGENT_TOKENS TG_BOT_PROJECT_SUBAGENT_BOTS
    export HEARTBEAT_PATROL_BOT_TOKEN HEARTBEAT_PATROL_CHAT_ID HEARTBEAT_PATROL_PROXY
    export TZ_NAME CRON_DAILY_DOCTOR CRON_UPSTREAM_WATCH CRON_WEEKLY_REVIEW CRON_MONTHLY_COMPRESS CRON_HERMES_DAILY_STUDY_UTC
    export KNOWN_GOOD_OPENCLAW_VERSION KNOWN_GOOD_HERMES_VERSION KNOWN_GOOD_NODE_VERSION KNOWN_GOOD_PYTHON_VERSION
    export HERMES_INSTALL_REF
}

# emit_journal_event: append a JSONL event to the evolution journal.
# Usage: emit_journal_event <event-name> <details-string> [actor]
#
# Default actor is "installer" — these events come from this template's
# install scripts, not from the running OpenClaw main agent. Mis-attributing
# them to "main" makes the journal harder to triage during a rescue.
# scripts/edit-baseline.sh passes actor="operator" explicitly.
emit_journal_event() {
    local event="$1" details="${2:-}" actor="${3:-installer}"
    local ts id
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    id="install-$(date +%s)-$$"
    mkdir -p "$(dirname "$JOURNAL")"
    [ -f "$JOURNAL" ] || touch "$JOURNAL"
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg ts "$ts" --arg event "$event" --arg actor "$actor" \
               --arg id "$id" --arg details "$details" \
            '{ts:$ts,event:$event,actor:$actor,id:$id,details:$details}' \
            >> "$JOURNAL"
    else
        printf '{"ts":"%s","event":"%s","actor":"%s","id":"%s","details":"%s"}\n' \
            "$ts" "$event" "$actor" "$id" "$details" >> "$JOURNAL"
    fi
}
