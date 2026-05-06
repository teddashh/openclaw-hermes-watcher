#!/usr/bin/env bash
# 00-prereqs.sh — sanity-check the host before install.
#
# Ensures OpenClaw is already installed (we don't install it), gh is auth'd,
# bash 4+, jq, curl, systemd --user enabled. Fails fast with actionable error
# messages.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

section "Pre-flight checks"

errors=0

check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "$name"
    else
        warn "$name"
        errors=$((errors + 1))
    fi
}

check_with_msg() {
    local name="$1" fail_msg="$2"; shift 2
    if "$@" >/dev/null 2>&1; then
        ok "$name"
    else
        warn "$name — $fail_msg"
        errors=$((errors + 1))
    fi
}

# Required tools
check "bash 4+ available"        bash -c '[[ "${BASH_VERSINFO[0]}" -ge 4 ]]'
check "jq present"               command -v jq
check "curl present"             command -v curl
check "envsubst present"         command -v envsubst
check "git present"              command -v git
check "sha256sum present"        command -v sha256sum
check "lsattr / chattr present"  command -v lsattr
check "systemctl --user works"   systemctl --user --version

# OpenClaw must already be installed
check_with_msg "openclaw on PATH" \
    "install OpenClaw first (https://docs.openclaw.ai)" \
    command -v openclaw

if command -v openclaw >/dev/null 2>&1; then
    if openclaw status >/dev/null 2>&1; then
        ok "openclaw status reports happy"
    else
        warn "openclaw status not happy — run 'openclaw doctor' before proceeding"
        errors=$((errors + 1))
    fi
fi

# Hermes can be installed by us, but if it's already there note the version
if command -v hermes >/dev/null 2>&1; then
    info "hermes already installed: $(hermes --version 2>/dev/null | head -1)"
else
    info "hermes not yet installed — 03-install-hermes.sh will install it"
fi

# gh CLI authenticated
check_with_msg "gh CLI authenticated" \
    "run 'gh auth login' interactively before proceeding" \
    gh auth status

# Workspace exists
check_with_msg "OpenClaw workspace exists at $WORKSPACE_DIR" \
    "OpenClaw main agent workspace not bootstrapped — run 'openclaw init' or equivalent" \
    test -d "$WORKSPACE_DIR"

# Linger enabled (so user systemd survives logout)
if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    ok "user linger enabled (systemd --user persists across logout)"
else
    warn "user linger NOT enabled — run: sudo loginctl enable-linger \$USER"
    info "  (without linger, the watcher and gateway stop when you log out)"
fi

# Config file present (machine.env)
if [ -f "$CONFIG_FILE" ]; then
    ok "machine.env present at $CONFIG_FILE"
else
    warn "machine.env missing — copy config/machine.env.example to config/machine.env and edit"
    errors=$((errors + 1))
fi

echo
if [ "$errors" -gt 0 ]; then
    die "Pre-flight failed with $errors issue(s) above. Fix before running 01-render.sh."
fi
ok "Pre-flight passed. Proceed to 01-render.sh."
