#!/usr/bin/env bash
# 03-install-hermes.sh — install Hermes Agent via upstream installer.
#
# Critical: --skip-setup (we configure manually in step 4) and we DO NOT run
# `hermes claw migrate` — that would absorb OpenClaw's SOUL/memory/skills/keys,
# which is the opposite of what we want.
#
# Idempotent. If hermes is already installed, this just verifies and exits.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

section "Install Hermes Agent"

if command -v hermes >/dev/null 2>&1; then
    ver=$(hermes --version 2>/dev/null | head -1 || echo unknown)
    ok "Hermes already installed: $ver"
    info "Re-running installer is safe but unnecessary."
    info "To upgrade later: run 'hermes update' from hermes-maintainer (after operator approval)."
    exit 0
fi

[ -d "$BASELINE_DIR" ] || die "Run 02-deploy-baseline.sh first"
[ -f "$BASELINE_DIR/baseline.policy.yaml" ] || die "Baseline missing"

emit_journal_event deploy_hermes_install_started ""

info "Downloading upstream Hermes installer at ref '${HERMES_INSTALL_REF}'..."
info "This will take 10-20 minutes (uv installs Python 3.11, builds extensions, installs deps)."
if [ "$HERMES_INSTALL_REF" = "main" ]; then
    warn "HERMES_INSTALL_REF=main — you are tracking the moving upstream branch."
    warn "  For reproducible installs across hosts, pin to a specific tag in machine.env."
fi
echo

curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_INSTALL_REF}/scripts/install.sh" \
    | bash -s -- --skip-setup

# Source bashrc so `hermes` becomes available in this shell
if [ -f ~/.bashrc ]; then
    set +u
    # shellcheck disable=SC1090
    source ~/.bashrc 2>/dev/null || true
    set -u
fi

if ! command -v hermes >/dev/null 2>&1; then
    export PATH="$HOME/.local/bin:$PATH"
fi

command -v hermes >/dev/null 2>&1 || die "Hermes binary not found after install. Check ~/.hermes/hermes-agent/ and ~/.local/bin/"

ver=$(hermes --version 2>/dev/null | head -1 || echo unknown)
ok "Hermes installed: $ver"
emit_journal_event deploy_hermes_install_completed "version=$ver"

# Lock ~/.hermes/.env permissions if it exists
if [ -f "$HOME/.hermes/.env" ]; then
    chmod 600 "$HOME/.hermes/.env"
    info "~/.hermes/.env permissions set to 600"
fi

# Confirm we did NOT auto-migrate
if [ -d "$HOME/.hermes/skills/openclaw-imports" ]; then
    warn "openclaw-imports/ exists — auto-migration may have run!"
    warn "Inspect ~/.hermes/skills/ and decide whether to keep or remove."
    emit_journal_event deploy_hermes_unexpected_migration_detected "openclaw-imports present"
else
    ok "No openclaw-imports detected — clean install (good)"
fi

if [ -f "$HOME/.hermes/SOUL.md" ]; then
    soul_size=$(wc -c < "$HOME/.hermes/SOUL.md")
    if [ "$soul_size" -gt 600 ]; then
        warn "~/.hermes/SOUL.md has content ($soul_size bytes) — possible auto-migration?"
    fi
fi

# On a fresh host, 01-render.sh ran BEFORE hermes existed on PATH, so
# load_config auto-detect fell back to KNOWN_GOOD_HERMES_VERSION="unknown".
# That string was envsubst'd into baseline.policy.yaml, MEMORY.md, etc., and
# 02-deploy-baseline.sh then chattr +i'd it. The hermes_upstream_watch cron
# would treat every release as "newer than unknown" forever.
#
# Fix: now that hermes is on PATH, re-render the templates (which re-runs
# load_config and detects the real version) and redeploy the baseline with
# --force to unfreeze + replace + refreeze. Idempotent on subsequent runs:
# if the version was already correct, nothing changes.
if hermes --version 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    info "Re-rendering templates with detected Hermes version + redeploying baseline..."
    # Subprocess so it sources a fresh load_config that picks up new PATH.
    bash "$SCRIPT_DIR/01-render.sh" || die "post-install re-render failed"
    bash "$SCRIPT_DIR/02-deploy-baseline.sh" --force || die "post-install baseline redeploy failed"
    ok "Baseline now reflects detected Hermes version"
fi

ok "Step 03 complete. Proceed to 04-configure-hermes.sh."
