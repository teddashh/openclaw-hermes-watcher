#!/usr/bin/env bash
# check-no-pii.sh — fail the build if any PII pattern leaked into tracked files.
#
# Two pattern sources, both optional:
#
# 1. GENERIC_REGEXES (defined below): structural patterns that look like real
#    PII regardless of who you are — real-looking emails, IPv4 literals (with
#    a small allowlist for loopback / RFC1918), Telegram bot-token shape.
#    These ship with the template so upstream PRs don't accidentally land
#    things like "contact me at me@gmail.com" or a forgotten test IP.
#
# 2. tests/.pii-patterns.local (gitignored): your own literal strings — your
#    name, your email, your bot username, your machine name. The committed
#    repo NEVER contains these. The file is sourced if it exists; otherwise
#    only the generic regexes run.
#
# Why both: generic regex catches shape but misses things like "Theodore" (a
# common name); literal patterns catch your own identifiers but operator-
# specific patterns must not be committed (that would leak the very PII the
# test guards against — exactly the bug an earlier draft of this script had).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_PATTERNS_FILE="$SCRIPT_DIR/.pii-patterns.local"

# Generic structural patterns — should never legitimately appear in a public
# template's tracked files. Add to this list when a new shape is identified
# (any pattern that doesn't depend on who the operator is).
GENERIC_REGEXES=(
    # Real-looking email addresses. Common test/placeholder domains are
    # allowlisted via a post-filter below.
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

    # Telegram bot token shape: 8+ digits, colon, 30+ url-safe chars.
    # Matches the canonical pattern @BotFather hands out. Almost certainly
    # a real token if it shows up.
    '\b[0-9]{8,12}:[A-Za-z0-9_-]{30,}\b'

    # Public-facing IPv4. Allowlists loopback / RFC1918 / TEST-NETs below.
    '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
)

# Two allowlists with different match semantics:
#
# IP_PREFIX_ALLOWLIST — IPv4-shaped matches must START with one of these.
# Substring containment is wrong here: "10." is a legitimate prefix for
# RFC1918 but a substring like "8.10.20.30" CONTAINS "10." while being a
# public IP that should leak as a finding.
IP_PREFIX_ALLOWLIST=(
    '127.'
    '10.'
    '172.16.'
    '172.17.'
    '172.18.'
    '172.19.'
    '172.20.'
    '172.21.'
    '172.22.'
    '172.23.'
    '172.24.'
    '172.25.'
    '172.26.'
    '172.27.'
    '172.28.'
    '172.29.'
    '172.30.'
    '172.31.'
    '192.168.'
    '0.0.0.0'
    '169.254.'
    '224.'
    '203.0.113.'    # TEST-NET-3
    '198.51.100.'   # TEST-NET-2
    '192.0.2.'      # TEST-NET-1
    '255.255.'      # broadcast / mask
)

# SUBSTRING_ALLOWLIST — non-IP matches (emails, bot tokens) are allowlisted
# if they CONTAIN one of these substrings. Conservative; we'd rather have
# false positives than false negatives.
SUBSTRING_ALLOWLIST=(
    'example.com'
    'example.org'
    'example.net'
    'placeholder'
    'your-name'
    'your-bot'
    'your-fork'
    'username'
    'noreply'
    'NousResearch'
    '::1'
    'TEST-NET'
)

# Read operator-specific patterns from .pii-patterns.local if present.
LOCAL_PATTERNS=()
if [ -f "$LOCAL_PATTERNS_FILE" ]; then
    # `|| [ -n "$line" ]` salvages a final line that has no trailing newline
    # (e.g., the operator added a pattern at the end of the file and saved
    # without a closing \n). Without this, that last — typically the most
    # recently added — pattern is silently dropped.
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        cleaned=$(echo "$line" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')
        [ -n "$cleaned" ] && LOCAL_PATTERNS+=("$cleaned")
    done < "$LOCAL_PATTERNS_FILE"
fi

# is_allowlisted: takes the actual *matched substring* (not the whole grep
# line) and returns 0 if it's a benign placeholder/loopback/RFC1918 string.
#
# History: an earlier draft compared against the whole grep line, which
# masked real leaks (a line containing both "10." and "8.8.8.8" was
# allowlisted because the line contained the allowed token somewhere).
# That was fixed by per-match comparison. THIS revision fixes a second
# bug: substring-containment for IP-shaped matches let public IPs like
# "8.10.20.30" through because they CONTAIN "10.". IP-shaped matches
# now use anchored prefix matching against IP_PREFIX_ALLOWLIST.
is_allowlisted() {
    local match="$1" allowed
    # IPv4-shaped match? Anchored prefix match against IP_PREFIX_ALLOWLIST.
    if [[ "$match" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        for allowed in "${IP_PREFIX_ALLOWLIST[@]}"; do
            [[ "$match" == "$allowed"* ]] && return 0
        done
        return 1
    fi
    # Non-IP (email, token, etc.): substring match anywhere.
    for allowed in "${SUBSTRING_ALLOWLIST[@]}"; do
        [[ "$match" == *"$allowed"* ]] && return 0
    done
    return 1
}

run_check() {
    local pattern="$1" label="$2" filtered=""
    local raw_lines
    raw_lines=$(cd "$REPO_ROOT" && \
        grep -RinE --exclude-dir=.git --exclude-dir=.render-cache \
                   --exclude="check-no-pii.sh" \
                   --exclude=".pii-patterns.local" \
                   --exclude=".pii-patterns.local.example" \
                   --exclude="machine.env" \
                   --exclude="machine.env.secrets" \
                   --exclude="heartbeat-patrol.env" \
            -- "$pattern" . 2>/dev/null || true)
    [ -z "$raw_lines" ] && return 0

    # For each matching grep line, extract just the matched substrings via
    # grep -oE, then check each match individually against the allowlist.
    # A line is reported only if AT LEAST ONE match on it is non-allowlisted.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Strip the "filename:lineno:" prefix grep adds, then -oE on body.
        local body="${line#*:}"; body="${body#*:}"
        local matches has_unallowed=false
        matches=$(echo "$body" | grep -oE -- "$pattern" 2>/dev/null || true)
        while IFS= read -r match; do
            [ -z "$match" ] && continue
            if ! is_allowlisted "$match"; then
                has_unallowed=true
                break
            fi
        done <<< "$matches"
        $has_unallowed && filtered+="$line"$'\n'
    done <<< "$raw_lines"

    [ -z "${filtered// }" ] && return 0
    echo "PII PATTERN LEAK ($label): $pattern"
    echo "$filtered" | head -5 | sed 's/^/  /'
    return 1
}

fails=0

for pattern in "${GENERIC_REGEXES[@]}"; do
    run_check "$pattern" "generic" || fails=$((fails + 1))
done

for pattern in "${LOCAL_PATTERNS[@]}"; do
    run_check "$pattern" "local" || fails=$((fails + 1))
done

if [ "${#LOCAL_PATTERNS[@]}" -eq 0 ]; then
    echo "[..] no $LOCAL_PATTERNS_FILE — only generic structural patterns checked."
    echo "     If you have operator-specific identifiers (real names, your bot tokens),"
    echo "     copy tests/.pii-patterns.local.example and add them there."
fi

if [ "$fails" -gt 0 ]; then
    echo
    echo "FAIL: $fails pattern(s) leaked. Fix above before committing."
    exit 1
fi

echo "OK: no PII patterns found in tracked files."
