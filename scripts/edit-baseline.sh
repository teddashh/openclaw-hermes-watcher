#!/usr/bin/env bash
# edit-baseline.sh — safely edit a chattr +i baseline file via $EDITOR.
#
# Usage: scripts/edit-baseline.sh <relative-baseline-filename>
#   e.g.: scripts/edit-baseline.sh machine-mission.md
#
# Procedure:
#   1. sudo chattr -i the file
#   2. open in $EDITOR
#   3. on save: regenerate sha256 fingerprints + meta-hash, sudo chattr +i again
#   4. emit journal event noting the operator-initiated edit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# load_config sets $OPERATOR_HANDLE etc.; without it the journal-event call at
# the end of this script would crash under set -u after the file is already
# re-frozen (silently dropping the audit entry).
load_config

[ "$#" -eq 1 ] || die "Usage: $0 <baseline-filename>  (e.g. machine-mission.md)"

NAME="$1"
TARGET="$BASELINE_DIR/$NAME"

[ -f "$TARGET" ] || die "Not a baseline file: $TARGET"

EDITOR_CMD="${EDITOR:-vim}"

info "Unfreezing $TARGET..."
sudo chattr -i "$TARGET" || die "chattr -i failed"
sudo chattr -i "$BASELINE_DIR/.expected-hashes" 2>/dev/null || true
sudo chattr -i "$BASELINE_DIR/.expected-hashes.sha256" 2>/dev/null || true

info "Opening in $EDITOR_CMD..."
"$EDITOR_CMD" "$TARGET"

info "Regenerating .expected-hashes..."
( cd "$BASELINE_DIR" && \
    find . -maxdepth 1 \( -name '*.yaml' -o -name '*.md' -o -name 'watcher.sh' \) \
        ! -name '.*' -print0 | sort -z | xargs -0 sha256sum > .expected-hashes )
sed -i 's| \./| |' "$BASELINE_DIR/.expected-hashes"
( cd "$BASELINE_DIR" && sha256sum .expected-hashes > .expected-hashes.sha256 )

info "Re-freezing..."
sudo chattr +i "$TARGET" \
              "$BASELINE_DIR/.expected-hashes" \
              "$BASELINE_DIR/.expected-hashes.sha256" \
    || die "chattr +i failed"

emit_journal_event "operator_edited_baseline" "file=$NAME by=$OPERATOR_HANDLE" "operator"
ok "Edited $TARGET; baseline re-frozen."
