#!/usr/bin/env bash
# 02-deploy-baseline.sh — deploy rendered baseline files + watcher systemd unit.
#
# Reads from .render-cache/ (output of 01-render.sh).
# Sets chattr +i on baseline files. Installs and starts the watcher.
#
# Idempotent: re-running unfreezes (sudo chattr -i), copies, refreezes if
# content differs. Pass --force to skip the "differs from cached" check.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_config

FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

OUT_DIR="$REPO_ROOT/.render-cache"
SYSTEMD_UNIT_PATH="$HOME/.config/systemd/user/openclaw-watcher.service"

section "Deploy baseline → $BASELINE_DIR"

[ -d "$OUT_DIR" ] || die "$OUT_DIR not found — run 01-render.sh first"
for f in baseline.policy.yaml hermes-permissions.yaml machine-mission.md watcher.sh openclaw-watcher.service; do
    [ -f "$OUT_DIR/$f" ] || die "Missing rendered file: $OUT_DIR/$f"
done

mkdir -p "$BASELINE_DIR" "$WORKSPACE_DIR"
[ -f "$JOURNAL" ] || touch "$JOURNAL"
emit_journal_event deploy_baseline_started "force=$FORCE"

is_immutable() { lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q 'i'; }

# Step A: detect existing immutable files, unfreeze if content differs
if [ -d "$BASELINE_DIR" ] && [ "$(ls -A "$BASELINE_DIR" 2>/dev/null)" ]; then
    any_immutable=false
    for f in "$BASELINE_DIR"/*; do
        [ -f "$f" ] || continue
        is_immutable "$f" && { any_immutable=true; break; }
    done

    content_differs=false
    for src in baseline.policy.yaml hermes-permissions.yaml machine-mission.md watcher.sh; do
        [ -f "$BASELINE_DIR/$src" ] || { content_differs=true; break; }
        if ! cmp -s "$OUT_DIR/$src" "$BASELINE_DIR/$src"; then
            content_differs=true
            break
        fi
    done

    if $any_immutable && $content_differs; then
        info "Unfreezing baseline (sudo chattr -i) for redeploy..."
        sudo chattr -R -i "$BASELINE_DIR" || die "chattr -i failed — sudo permissions?"
    elif $any_immutable && ! $content_differs; then
        info "Baseline immutable AND content matches render — idempotent rerun"
    fi
fi

# Step B: copy rendered files
copy_if_changed() {
    local src="$1" dst="$2"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        info "  unchanged: $(basename "$dst")"
    else
        cp "$src" "$dst"
        ok "  copied:    $(basename "$dst")"
    fi
}

copy_if_changed "$OUT_DIR/baseline.policy.yaml"    "$BASELINE_DIR/baseline.policy.yaml"
copy_if_changed "$OUT_DIR/hermes-permissions.yaml" "$BASELINE_DIR/hermes-permissions.yaml"
copy_if_changed "$OUT_DIR/machine-mission.md"      "$BASELINE_DIR/machine-mission.md"
copy_if_changed "$OUT_DIR/watcher.sh"              "$BASELINE_DIR/watcher.sh"
[ -x "$BASELINE_DIR/watcher.sh" ] || chmod +x "$BASELINE_DIR/watcher.sh"

# Step C: regenerate sha256 fingerprints if needed
if [ -f "$BASELINE_DIR/.expected-hashes" ] && \
   [ -f "$BASELINE_DIR/.expected-hashes.sha256" ] && \
   ( cd "$BASELINE_DIR" && sha256sum -c .expected-hashes --quiet 2>/dev/null ) && \
   ( cd "$BASELINE_DIR" && sha256sum -c .expected-hashes.sha256 --quiet 2>/dev/null ); then
    info ".expected-hashes already match"
else
    info "Generating .expected-hashes + meta-hash"
    if [ -f "$BASELINE_DIR/.expected-hashes" ] && is_immutable "$BASELINE_DIR/.expected-hashes"; then
        sudo chattr -i "$BASELINE_DIR/.expected-hashes" 2>/dev/null || true
    fi
    if [ -f "$BASELINE_DIR/.expected-hashes.sha256" ] && is_immutable "$BASELINE_DIR/.expected-hashes.sha256"; then
        sudo chattr -i "$BASELINE_DIR/.expected-hashes.sha256" 2>/dev/null || true
    fi
    ( cd "$BASELINE_DIR" && \
        find . -maxdepth 1 \( -name '*.yaml' -o -name '*.md' -o -name 'watcher.sh' \) \
            ! -name '.*' -print0 | sort -z | xargs -0 sha256sum > .expected-hashes )
    sed -i 's| \./| |' "$BASELINE_DIR/.expected-hashes"
    ( cd "$BASELINE_DIR" && sha256sum .expected-hashes > .expected-hashes.sha256 )
    ok ".expected-hashes ($(wc -l < "$BASELINE_DIR/.expected-hashes") files) + meta"
fi

# Step D: install systemd user unit for watcher
mkdir -p "$(dirname "$SYSTEMD_UNIT_PATH")"
if [ -f "$SYSTEMD_UNIT_PATH" ] && is_immutable "$SYSTEMD_UNIT_PATH"; then
    sudo chattr -i "$SYSTEMD_UNIT_PATH" || die "could not unfreeze unit"
fi
if systemctl --user is-active openclaw-watcher >/dev/null 2>&1; then
    info "Stopping running watcher before unit replacement"
    systemctl --user stop openclaw-watcher
fi
if [ -f "$SYSTEMD_UNIT_PATH" ] && cmp -s "$OUT_DIR/openclaw-watcher.service" "$SYSTEMD_UNIT_PATH"; then
    info "unit unchanged"
else
    cp "$OUT_DIR/openclaw-watcher.service" "$SYSTEMD_UNIT_PATH"
    ok "unit installed at $SYSTEMD_UNIT_PATH"
fi
systemctl --user daemon-reload
systemctl --user enable openclaw-watcher >/dev/null 2>&1
ok "watcher unit enabled"

# Step E: chattr +i on baseline content
info "Applying chattr +i to baseline (sudo)..."
sudo chattr +i "$BASELINE_DIR/baseline.policy.yaml" \
              "$BASELINE_DIR/hermes-permissions.yaml" \
              "$BASELINE_DIR/machine-mission.md" \
              "$BASELINE_DIR/watcher.sh" \
              "$BASELINE_DIR/.expected-hashes" \
              "$BASELINE_DIR/.expected-hashes.sha256" \
    || die "chattr +i failed"
ok "baseline frozen (chattr +i)"

# Step F: start watcher
info "Starting openclaw-watcher..."
systemctl --user start openclaw-watcher
sleep 2
if systemctl --user is-active openclaw-watcher >/dev/null 2>&1; then
    ok "watcher is running"
else
    journalctl --user -u openclaw-watcher --no-pager -n 20 2>&1 | sed 's/^/  /' || true
    emit_journal_event deploy_baseline_watcher_failed_to_start "see journalctl"
    die "openclaw-watcher failed to start. Halting to avoid leaving baseline unenforced."
fi

# Step G: bootstrap workspace dirs the rest of install will need
mkdir -p "$WORKSPACE_DIR/upgrade-packs/inbox" \
         "$WORKSPACE_DIR/heartbeats"

# Stub openclaw-local-diff.md if missing (operator maintains; Hermes reads RO)
LOCAL_DIFF_DOC="$WORKSPACE_DIR/openclaw-local-diff.md"
if [ ! -f "$LOCAL_DIFF_DOC" ]; then
    cat > "$LOCAL_DIFF_DOC" <<'EOF'
# OpenClaw Local Diff

> Living document. Operator maintains; Hermes reads (RO).
> Document each intentional deviation from upstream openclaw/openclaw on this host.
> Format per entry: brief title, why-it-exists, files-touched, upstream-equivalent (if any).

## Diffs from upstream

(none documented yet)

## Rationale archive

(retired diffs and why we dropped them)
EOF
    ok "stubbed $LOCAL_DIFF_DOC"
fi

emit_journal_event deploy_baseline_completed "files=$(ls -1 "$BASELINE_DIR" | wc -l)"
ok "Step 02 complete. Proceed to 03-install-hermes.sh."
