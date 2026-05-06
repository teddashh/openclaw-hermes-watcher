#!/usr/bin/env bash
# render-template.sh — substitute $VAR placeholders in templates using envsubst.
#
# Usage: render_template <input-file> <output-file>
# Sources $REPO_ROOT/config/machine.env to get user values.
# Uses envsubst with an explicit allowlist so unrelated $X tokens in templates
# (e.g. embedded shell snippets, $(date), backslash-dollar literals) survive.
#
# The allowlist comes from a single source of truth, ALLOWED_VARS, which
# enumerates every placeholder the templates may legally contain. Adding a
# new placeholder requires adding it here AND consumers should fail loudly
# if a template references something not on the list.

# Allowlist of variables that templates may reference. Keep this in sync
# with config/machine.env.example.
ALLOWED_VARS=(
    OPERATOR_NAME
    OPERATOR_EMAIL
    OPERATOR_HANDLE
    OPERATOR_LOCATION
    OPERATOR_LANGUAGES
    OPERATOR_TELEGRAM_USER_ID

    MACHINE_NAME
    MACHINE_OS
    MACHINE_ROLE
    MACHINE_SERVICES_MD
    MACHINE_OUT_OF_SCOPE_MD

    TG_BOT_MAIN_TOKEN
    TG_BOT_MAIN_NAME
    TG_BOT_HERMES_MAINTAINER_TOKEN
    TG_BOT_HERMES_MAINTAINER_NAME
    TG_BOT_HERMES_AGENT_TOKEN
    TG_BOT_HERMES_AGENT_NAME
    TG_BOT_PROJECT_SUBAGENT_NAMES
    TG_BOT_PROJECT_SUBAGENT_TOKENS
    TG_BOT_PROJECT_SUBAGENT_BOTS

    HEARTBEAT_PATROL_BOT_TOKEN
    HEARTBEAT_PATROL_CHAT_ID
    HEARTBEAT_PATROL_PROXY

    TZ_NAME
    CRON_DAILY_DOCTOR
    CRON_UPSTREAM_WATCH
    CRON_WEEKLY_REVIEW
    CRON_MONTHLY_COMPRESS
    CRON_HERMES_DAILY_STUDY_UTC

    KNOWN_GOOD_OPENCLAW_VERSION
    KNOWN_GOOD_HERMES_VERSION
    KNOWN_GOOD_NODE_VERSION
    KNOWN_GOOD_PYTHON_VERSION

    HOME
)

# Build the envsubst-style allowlist string: '$VAR1 $VAR2 ...'
_render_template_allowlist() {
    local out=""
    local v
    for v in "${ALLOWED_VARS[@]}"; do
        out+=" \$$v"
    done
    printf '%s' "$out"
}

# render_template <input> <output>
render_template() {
    local in="$1" out="$2"
    [ -f "$in" ] || { echo "render_template: missing input $in" >&2; return 1; }
    mkdir -p "$(dirname "$out")"
    local allowlist
    allowlist=$(_render_template_allowlist)
    envsubst "$allowlist" < "$in" > "$out"
}

# Convenience: render to stdout
render_template_stdout() {
    local in="$1"
    [ -f "$in" ] || { echo "render_template_stdout: missing input $in" >&2; return 1; }
    local allowlist
    allowlist=$(_render_template_allowlist)
    envsubst "$allowlist" < "$in"
}
