#!/bin/bash
# watcher.sh — OpenClaw baseline sentinel.
# See ARCHITECTURE.md (or docs/PHASE-2.5-HEARTBEAT.md) for the design rationale.
#
# Runs forever (systemd Restart=on-failure). Every 60s:
#   - verify chattr +i flag still set on baseline files
#   - verify sha256 hashes of baseline files match expected (with meta-hash)
#   - verify openclaw-gateway is running
#   - emit JSONL events to evolution-journal on anomalies
#
# This script is rule-based, not LLM-based. It cannot be talked into anything.
# It is itself chattr +i after deployment.

set -euo pipefail

BASELINE_DIR="${BASELINE_DIR:-$HOME/.openclaw/workspace/baseline}"
JOURNAL="${JOURNAL:-$HOME/.openclaw/workspace/evolution-journal.jsonl}"
EXPECTED_HASHES_FILE="$BASELINE_DIR/.expected-hashes"
INTERVAL_SEC="${INTERVAL_SEC:-60}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

emit_event() {
    local event="$1"
    local details="$2"
    local actor="${3:-watcher}"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local id
    id="watcher-$(date +%s)-$$"

    # Use jq -nc to safely build JSON; falls back to bare echo if jq missing
    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg ts "$ts" \
            --arg event "$event" \
            --arg actor "$actor" \
            --arg id "$id" \
            --arg details "$details" \
            '{ts: $ts, event: $event, actor: $actor, id: $id, details: $details}' \
            >> "$JOURNAL"
    else
        # Last-ditch JSON construction without jq (escaping limited)
        printf '{"ts":"%s","event":"%s","actor":"%s","id":"%s","details":"%s"}\n' \
            "$ts" "$event" "$actor" "$id" "$details" >> "$JOURNAL"
    fi
}

emit_heartbeat() {
    # Once per hour, emit a heartbeat so we know the watcher is alive
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local id
    id="watcher-heartbeat-$(date +%s)"

    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg ts "$ts" \
            --arg id "$id" \
            '{ts: $ts, event: "watcher_heartbeat", actor: "watcher", id: $id}' \
            >> "$JOURNAL"
    else
        printf '{"ts":"%s","event":"watcher_heartbeat","actor":"watcher","id":"%s"}\n' \
            "$ts" "$id" >> "$JOURNAL"
    fi
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_immutability() {
    # Every yaml/md/sh in baseline dir + .expected-hashes + .expected-hashes.sha256
    # should have the +i flag.
    #
    # Note: do NOT capture `find -print0` into a shell variable — command
    # substitution drops NUL bytes, collapsing the whole list to a single
    # token. We pipe directly into the read loop instead.
    local lost=0

    while IFS= read -r -d '' f; do
        [ -z "$f" ] && continue
        if ! lsattr "$f" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            emit_event "baseline_immutability_lost" "$f"
            lost=1
        fi
    done < <(
        find "$BASELINE_DIR" -maxdepth 1 \( -name '*.yaml' -o -name '*.md' -o -name '*.sh' \) -print0
        for extra in "$EXPECTED_HASHES_FILE" "${EXPECTED_HASHES_FILE}.sha256"; do
            [ -f "$extra" ] && printf '%s\0' "$extra"
        done
    )

    return $lost
}

check_hashes() {
    # All baseline file hashes should match recorded fingerprints, AND
    # .expected-hashes itself must hash to its recorded value (otherwise an
    # attacker who flipped chattr -i could rewrite both the data file and
    # .expected-hashes in lockstep). We store the recorded hash of
    # .expected-hashes itself in $EXPECTED_HASHES_FILE.sha256 (separate file
    # to avoid the chicken-and-egg of self-referencing).
    if [ ! -f "$EXPECTED_HASHES_FILE" ]; then
        emit_event "baseline_hashes_file_missing" "$EXPECTED_HASHES_FILE"
        return 1
    fi

    # Verify the integrity of .expected-hashes itself if a meta-hash exists
    local meta_hash_file="${EXPECTED_HASHES_FILE}.sha256"
    if [ -f "$meta_hash_file" ]; then
        local recorded actual
        recorded=$(awk '{print $1}' "$meta_hash_file")
        actual=$(sha256sum "$EXPECTED_HASHES_FILE" | awk '{print $1}')
        if [ "$recorded" != "$actual" ]; then
            emit_event "baseline_meta_hash_mismatch" "expected=$recorded actual=$actual file=$EXPECTED_HASHES_FILE"
            return 1
        fi
    fi

    # `sha256sum -c` resolves the filenames in the hash file as RELATIVE
    # paths against the current working directory. .expected-hashes uses
    # bare basenames, so we must cd before running -c.
    if ! ( cd "$BASELINE_DIR" && sha256sum -c .expected-hashes --quiet ) 2>/dev/null; then
        local bad
        bad=$( cd "$BASELINE_DIR" && sha256sum -c .expected-hashes 2>&1 | grep -v ': OK$' | head -3 | tr '\n' ';' )
        emit_event "baseline_hash_mismatch" "$bad"
        return 1
    fi
    return 0
}

check_openclaw_gateway() {
    # OpenClaw should always be running
    if ! pgrep -f 'openclaw.*gateway' >/dev/null 2>&1; then
        emit_event "openclaw_gateway_not_running" ""
        return 1
    fi
    return 0
}

check_journal_writable() {
    # Sanity check we can append to the journal
    if [ ! -w "$JOURNAL" ]; then
        # Cannot use emit_event here since journal is what's broken
        echo "watcher: journal not writable: $JOURNAL" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

main() {
    if [ ! -d "$BASELINE_DIR" ]; then
        echo "watcher: baseline dir missing: $BASELINE_DIR" >&2
        exit 1
    fi

    if [ ! -f "$JOURNAL" ]; then
        touch "$JOURNAL" || { echo "watcher: cannot create journal" >&2; exit 1; }
    fi

    emit_event "watcher_started" "interval=${INTERVAL_SEC}s baseline_dir=$BASELINE_DIR"

    local hour_marker
    hour_marker=$(date +%H)

    while true; do
        # If the journal isn't writable, no point running the other checks —
        # their emit_event calls would silently drop into the dead file.
        # Sleep and try again next cycle.
        if ! check_journal_writable; then
            sleep "$INTERVAL_SEC"
            continue
        fi
        check_immutability     || true
        check_hashes           || true
        check_openclaw_gateway || true

        local now_hour
        now_hour=$(date +%H)
        if [ "$now_hour" != "$hour_marker" ]; then
            emit_heartbeat
            hour_marker=$now_hour
        fi

        sleep "$INTERVAL_SEC"
    done
}

# Trap SIGTERM (systemd stop) gracefully
trap 'emit_event "watcher_stopped" "received SIGTERM"; exit 0' TERM INT

main
