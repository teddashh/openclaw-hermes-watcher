#!/usr/bin/env bash
# 07-smoke-test.sh — verify install end-to-end.
# Counts passed/warned/failed; exits non-zero on any FAIL.

set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

PASS=0; FAIL=0; WARN=0
pass() { ok "$*"; PASS=$((PASS + 1)); }
fail() { echo "${RED}[FAIL]${NC} $*" >&2; FAIL=$((FAIL + 1)); }
warn_count() { warn "$*"; WARN=$((WARN + 1)); }

assert_file()    { [ -f "$1" ] && pass "file $1" || fail "missing $1"; }
assert_dir()     { [ -d "$1" ] && pass "dir $1"  || fail "missing $1"; }
assert_cmd()     { command -v "$1" >/dev/null 2>&1 && pass "cmd $1" || fail "missing cmd $1"; }
assert_immutable() { lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q 'i' && pass "chattr +i $1" || fail "$1 not chattr +i"; }
assert_systemd_active() { systemctl --user is-active "$1" >/dev/null 2>&1 && pass "systemd $1 active" || fail "$1 not active"; }
assert_cron_exists()   { openclaw cron list --json 2>/dev/null | jq -e --arg n "$1" '.jobs[]? | select(.name == $n)' >/dev/null && pass "cron $1 registered" || fail "cron $1 missing"; }

section "Smoke test"

# Tools
assert_cmd openclaw
assert_cmd hermes
assert_cmd jq
assert_cmd curl

# Workspace
assert_dir "$WORKSPACE_DIR"
assert_dir "$BASELINE_DIR"
assert_file "$BASELINE_DIR/baseline.policy.yaml"
assert_file "$BASELINE_DIR/hermes-permissions.yaml"
assert_file "$BASELINE_DIR/machine-mission.md"
assert_file "$BASELINE_DIR/watcher.sh"
assert_file "$BASELINE_DIR/.expected-hashes"
assert_file "$BASELINE_DIR/.expected-hashes.sha256"

# Immutable
assert_immutable "$BASELINE_DIR/baseline.policy.yaml"
assert_immutable "$BASELINE_DIR/hermes-permissions.yaml"
assert_immutable "$BASELINE_DIR/machine-mission.md"
assert_immutable "$BASELINE_DIR/watcher.sh"

# Hash check via sha256sum -c
if ( cd "$BASELINE_DIR" && sha256sum -c .expected-hashes --quiet ) 2>/dev/null; then
    pass "baseline sha256 fingerprints match"
else
    fail "baseline sha256 fingerprints mismatch"
fi

# Watcher service
assert_systemd_active openclaw-watcher

# Heartbeat infrastructure
assert_file "$HOME/.local/bin/heartbeat-patrol"
assert_dir  "$WORKSPACE_DIR/heartbeats"
assert_dir  "$HOME/.hermes/heartbeats"
assert_file "$WORKSPACE_DIR/heartbeats/hermes_daily_doctor.last"
assert_file "$WORKSPACE_DIR/heartbeats/hermes_upstream_watch.last"
assert_file "$WORKSPACE_DIR/heartbeats/hermes_weekly_review.last"
assert_file "$WORKSPACE_DIR/heartbeats/hermes_monthly_compress.last"
assert_file "$HOME/.hermes/heartbeats/hermes_daily_study.last"

# Upgrade-packs inbox
assert_dir "$WORKSPACE_DIR/upgrade-packs/inbox"
assert_file "$WORKSPACE_DIR/openclaw-local-diff.md"

# Hermes profile
PROFILE_CONFIG_PATH=$(hermes -p openclaw-evolution config path 2>/dev/null | head -1)
if [ -n "${PROFILE_CONFIG_PATH:-}" ]; then
    PROFILE_DIR=$(dirname "$PROFILE_CONFIG_PATH")
    pass "Hermes profile openclaw-evolution exists ($PROFILE_DIR)"
    assert_file "$PROFILE_DIR/SOUL.md"
    assert_file "$HOME/.hermes/memories/USER.md"
    assert_file "$HOME/.hermes/memories/MEMORY.md"
else
    fail "Hermes profile openclaw-evolution not found"
fi

# Cron jobs
assert_cron_exists hermes_daily_doctor
assert_cron_exists hermes_upstream_watch
assert_cron_exists hermes_weekly_review
assert_cron_exists hermes_monthly_compress

# Hermes-side cron
if hermes -p openclaw-evolution cron list 2>/dev/null | grep -q openclaw-daily-study; then
    pass "Hermes openclaw-daily-study cron registered"
else
    fail "Hermes openclaw-daily-study cron missing"
fi

# Maintainer subagent registered
if openclaw agents list 2>/dev/null | grep -qE '\bhermes-maintainer\b'; then
    pass "hermes-maintainer subagent registered"
else
    fail "hermes-maintainer subagent missing"
fi

# Heartbeat-patrol can run (dry test)
if "$HOME/.local/bin/heartbeat-patrol" --self hermes_daily_doctor 2>/dev/null \
        | grep -q "OK hermes_daily_doctor heartbeat"; then
    pass "heartbeat-patrol runs"
else
    warn_count "heartbeat-patrol returned non-OK output"
fi

# OpenClaw + Hermes happy
if openclaw status >/dev/null 2>&1; then
    pass "openclaw status OK"
else
    warn_count "openclaw status not OK — run 'openclaw doctor'"
fi

if hermes doctor 2>/dev/null | grep -q -i "ok\|good\|healthy"; then
    pass "hermes doctor OK"
else
    warn_count "hermes doctor reports issues — run 'hermes doctor' to inspect"
fi

echo
echo "${BLUE}==>${NC} Result: ${GREEN}$PASS pass${NC}, ${YELLOW}$WARN warn${NC}, ${RED}$FAIL fail${NC}"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
