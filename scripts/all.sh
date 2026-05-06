#!/usr/bin/env bash
# all.sh — orchestrate the full install, in order.
# Idempotent: each step is safe to re-run.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

steps=(
    00-prereqs.sh
    01-render.sh
    02-deploy-baseline.sh
    03-install-hermes.sh
    04-configure-hermes.sh
    05-register-maintainer.sh
    06-cron-setup.sh
    07-smoke-test.sh
    08-finalize.sh
    09-talk-helpers.sh
    10-tg-maintainer.sh
    11-tg-hermes.sh
)

for step in "${steps[@]}"; do
    echo
    echo "===================================================================="
    echo " $step"
    echo "===================================================================="
    bash "$SCRIPT_DIR/$step" || {
        echo
        echo "FAILED at $step. Fix the above issue and re-run 'bash scripts/all.sh'."
        exit 1
    }
done

echo
echo "All steps complete."
