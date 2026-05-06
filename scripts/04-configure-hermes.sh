#!/usr/bin/env bash
# 04-configure-hermes.sh — create the openclaw-evolution profile and write
# its SOUL/USER/MEMORY from the rendered templates.
#
# Idempotent.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

PROFILE="openclaw-evolution"
OUT_DIR="$REPO_ROOT/.render-cache"

section "Configure Hermes profile: $PROFILE"

command -v hermes >/dev/null 2>&1 || die "hermes not on PATH — did 03 run?"
[ -f "$BASELINE_DIR/machine-mission.md" ] || die "Baseline missing"
[ -f "$OUT_DIR/SOUL.md" ] || die "Run 01-render.sh first"

emit_journal_event deploy_configure_hermes_started "profile=$PROFILE"

# Step A: profile create (idempotent — if exists, reuse)
info "Creating profile '$PROFILE' (idempotent)..."
if hermes profile create "$PROFILE" --no-alias >/dev/null 2>&1; then
    ok "Profile '$PROFILE' created"
elif hermes profile list 2>/dev/null | grep -q "\b$PROFILE\b"; then
    info "Profile '$PROFILE' already exists — reusing"
elif hermes -p "$PROFILE" config show >/dev/null 2>&1; then
    info "Profile '$PROFILE' exists per 'config show' — reusing"
else
    die "Could not create or locate profile '$PROFILE'. Run 'hermes profile list' and 'hermes doctor'."
fi

# Step B: find profile dir via hermes config path
config_path_lines=$(hermes -p "$PROFILE" config path 2>/dev/null) \
    || die "hermes config path failed for profile $PROFILE"
config_path=$(printf '%s\n' "$config_path_lines" | head -1)
PROFILE_DIR=$(dirname "$config_path")
[ -d "$PROFILE_DIR" ] || die "Profile dir not found: $PROFILE_DIR"
ok "Profile dir: $PROFILE_DIR"

# Step C: write SOUL.md (per-profile)
#
# SOUL.md is mutable agent state — Hermes itself rewrites it during the
# Thursday self-correct rotation, the operator may hand-edit it, and the
# upstream template's SOUL.md.tmpl may also evolve. None of these three
# wins by default. Behavior:
#   - missing -> write fresh from rendered template (initial install)
#   - exists, identical to rendered -> no-op
#   - exists, differs from rendered -> preserve current, warn so operator
#     decides whether to roll forward
# To force-update SOUL from upstream: `rm $PROFILE_DIR/SOUL.md` and re-run.
if [ ! -f "$PROFILE_DIR/SOUL.md" ]; then
    cp "$OUT_DIR/SOUL.md" "$PROFILE_DIR/SOUL.md"
    ok "SOUL.md written to $PROFILE_DIR (initial)"
elif cmp -s "$OUT_DIR/SOUL.md" "$PROFILE_DIR/SOUL.md"; then
    info "SOUL.md unchanged — preserving"
else
    warn "SOUL.md exists at $PROFILE_DIR/SOUL.md and differs from rendered template."
    warn "  Hermes may have self-corrected this file, or you may have hand-edited it."
    warn "  Preserving current. To force-update from upstream:"
    warn "    rm $PROFILE_DIR/SOUL.md && bash scripts/04-configure-hermes.sh"
fi

# Step D: write USER.md and MEMORY.md to GLOBAL ~/.hermes/memories/
# (per Hermes docs: SOUL is per-profile, MEMORY/USER are shared across profiles)
MEMORIES_DIR="$HOME/.hermes/memories"
mkdir -p "$MEMORIES_DIR"

if [ ! -f "$MEMORIES_DIR/USER.md" ]; then
    cp "$OUT_DIR/USER.md" "$MEMORIES_DIR/USER.md"
    ok "USER.md written to $MEMORIES_DIR (global)"
else
    info "USER.md already exists at $MEMORIES_DIR — preserving (operator may have edited)"
fi

if [ ! -f "$MEMORIES_DIR/MEMORY.md" ]; then
    cp "$OUT_DIR/MEMORY.md" "$MEMORIES_DIR/MEMORY.md"
    ok "MEMORY.md written to $MEMORIES_DIR (global)"
elif grep -qE 'version at install: unknown|Bootstrapped at TBD' "$MEMORIES_DIR/MEMORY.md" 2>/dev/null; then
    # Earlier botched install left "unknown" baked in. Refresh from the
    # rendered template (which now has the correct values because 03 re-ran
    # 01-render after Hermes was on PATH).
    warn "MEMORY.md contains 'unknown' or 'TBD' from an earlier bootstrap — refreshing"
    cp "$OUT_DIR/MEMORY.md" "$MEMORIES_DIR/MEMORY.md"
else
    info "MEMORY.md already exists at $MEMORIES_DIR — preserving"
fi

# Step E: configure profile (model, etc.) via hermes config set
# We try with --strict-json first (newer hermes); fall back to plain config set.
config_set() {
    local key="$1" val="$2"
    if hermes -p "$PROFILE" config set "$key" "$val" --strict-json >/dev/null 2>&1; then
        ok "  $key = $val"
    elif hermes -p "$PROFILE" config set "$key" "$val" >/dev/null 2>&1; then
        ok "  $key = $val"
    else
        warn "  failed to set $key (continuing)"
    fi
}

info "Setting profile config..."
# Phase 1 invariants: gateway off; we'll enable in Phase 2 if user has a token
config_set messaging.telegram.enabled false
config_set messaging.discord.enabled false
config_set messaging.slack.enabled false

emit_journal_event deploy_configure_hermes_completed "profile=$PROFILE"
ok "Step 04 complete. Proceed to 05-register-maintainer.sh."
