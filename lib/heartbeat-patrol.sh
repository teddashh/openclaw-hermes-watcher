#!/usr/bin/env bash
# heartbeat-patrol: bidirectional cron heartbeat + dead-man-switch alerter.
#
# The four maintainer-side cron jobs call this once, as the FIRST step of each
# run: scripts/06-cron-setup.sh puts `heartbeat-patrol --self <job>` at the top
# of every job prompt, so the heartbeat lands even if the task itself fails.
# The Hermes-side daily study does not call it. Hermes's shell is chroot-jailed,
# so its prompt has it write its own heartbeat with a file tool and patrol the
# four maintainer heartbeats itself. This script still checks the Hermes
# heartbeat as a peer.
#
# The script:
#   1. Writes the calling job's heartbeat into that job's JOB_DIR (maintainer
#      jobs -> ~/.openclaw/workspace/heartbeats/, hermes_daily_study ->
#      ~/.hermes/heartbeats/).
#   2. Reads every OTHER job's heartbeat and computes staleness (now - last)
#      against that job's registered interval+grace.
#   3. If any peer is stale, appends to ~/.openclaw/workspace/heartbeats/_alerts.log
#      and, if both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are set, sends a
#      Telegram message (through TELEGRAM_PROXY when that is set).
#
# Inverse-heartbeat dead-man-switch: a fresh write IS the "I'm alive" signal;
# staleness IS the alert condition. A job that misses its run leaves a stale
# heartbeat, and the next peer that runs reports it.
#
# Source of truth: openclaw-hermes-watcher/lib/heartbeat-patrol.sh
# Installed at:    ~/.local/bin/heartbeat-patrol  (chmod 755, by scripts/06)
# Alert config at: ~/.config/heartbeat-patrol.env (chmod 600, by scripts/06)
#                  Format:
#                    TELEGRAM_BOT_TOKEN=<bot_token>
#                    TELEGRAM_CHAT_ID=<chat_id>
#                    TELEGRAM_PROXY=http://127.0.0.1:8118  # optional
#
# Usage: heartbeat-patrol --self <job-name>
# Known jobs are registered in JOB_INTERVAL/JOB_GRACE/JOB_DIR below; update
# them when adding/removing scheduled cron jobs on this host.

# `set -e` so a failed heartbeat write (chattr +i, ENOSPC, RO remount, NFS
# hiccup) aborts the script instead of silently printing "OK" while peers
# slowly fire false-positive STALE alerts ~33 days later. The patrol loop
# below explicitly suppresses errors where benign-missing-file is expected
# (peer heartbeat absent, malformed ISO timestamp), so set -e doesn't break
# the patrol logic.
set -euo pipefail

ALERT_CONF="$HOME/.config/heartbeat-patrol.env"
[ -f "$ALERT_CONF" ] && source "$ALERT_CONF"
ALERT_LOG="$HOME/.openclaw/workspace/heartbeats/_alerts.log"

# ----- Job catalog -----------------------------------------------------------
# When adding a new cron, add an entry here. Staleness is computed as:
# (now - last_heartbeat) > (interval + grace) hours.
declare -A JOB_INTERVAL JOB_GRACE JOB_DIR

# Maintainer-side jobs (~/.openclaw/workspace/heartbeats/)
JOB_INTERVAL[hermes_daily_doctor]=24
JOB_GRACE[hermes_daily_doctor]=6
JOB_DIR[hermes_daily_doctor]="$HOME/.openclaw/workspace/heartbeats"

JOB_INTERVAL[hermes_upstream_watch]=24
JOB_GRACE[hermes_upstream_watch]=6
JOB_DIR[hermes_upstream_watch]="$HOME/.openclaw/workspace/heartbeats"

JOB_INTERVAL[hermes_weekly_review]=168
JOB_GRACE[hermes_weekly_review]=24
JOB_DIR[hermes_weekly_review]="$HOME/.openclaw/workspace/heartbeats"

JOB_INTERVAL[hermes_monthly_compress]=720
JOB_GRACE[hermes_monthly_compress]=72
JOB_DIR[hermes_monthly_compress]="$HOME/.openclaw/workspace/heartbeats"

# Hermes-side jobs (~/.hermes/heartbeats/)
JOB_INTERVAL[hermes_daily_study]=24
JOB_GRACE[hermes_daily_study]=6
JOB_DIR[hermes_daily_study]="$HOME/.hermes/heartbeats"

# ----- Args ------------------------------------------------------------------
SELF=""
usage() {
  echo "Usage: $0 --self <job-name>" >&2
  echo "Known jobs: ${!JOB_INTERVAL[@]}" >&2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --self)
      # Use ${2:-} so a bare `--self` (no value) hits the friendly usage path
      # instead of crashing under set -u on unbound $2.
      SELF="${2:-}"
      if [ -z "$SELF" ]; then
        echo "$0: --self requires a job-name argument" >&2
        usage; exit 2
      fi
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 --self <job-name>"
      echo "Known jobs: ${!JOB_INTERVAL[@]}"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$SELF" ] || [ -z "${JOB_INTERVAL[$SELF]:-}" ]; then
  usage
  exit 2
fi

# ----- 1. Write own heartbeat -----------------------------------------------
# Belt-and-suspenders: set -e above already aborts on a failed redirection,
# but we ALSO test the file post-write so the OK line never fires after a
# silent partial write (e.g., disk full mid-write). The dead-man-switch
# must not lie about its own state.
SELF_DIR="${JOB_DIR[$SELF]}"
mkdir -p "$SELF_DIR"
NOW_ISO=$(date -Iseconds)
NOW_EPOCH=$(date +%s)
HB_LINE="$NOW_ISO interval=${JOB_INTERVAL[$SELF]}h grace=${JOB_GRACE[$SELF]}h job=$SELF"
echo "$HB_LINE" > "$SELF_DIR/$SELF.last"
# Verify the write actually landed (read back; compare).
if ! grep -qxF "$HB_LINE" "$SELF_DIR/$SELF.last" 2>/dev/null; then
    echo "$0: heartbeat write to $SELF_DIR/$SELF.last did not persist as expected" >&2
    exit 1
fi
echo "OK $SELF heartbeat written at $NOW_ISO"

# ----- 2. Patrol peers -------------------------------------------------------
ALERTS=()
for peer in "${!JOB_INTERVAL[@]}"; do
  [ "$peer" = "$SELF" ] && continue
  hb="${JOB_DIR[$peer]}/$peer.last"
  if [ ! -f "$hb" ]; then
    ALERTS+=("STALE: $peer (no heartbeat ever)")
    continue
  fi
  last_iso=$(awk '{print $1}' "$hb" 2>/dev/null)
  last_epoch=$(date -d "$last_iso" +%s 2>/dev/null || echo 0)
  if [ "$last_epoch" = "0" ]; then
    ALERTS+=("STALE: $peer (unreadable heartbeat)")
    continue
  fi
  interval=${JOB_INTERVAL[$peer]}
  grace=${JOB_GRACE[$peer]}
  limit_seconds=$(( (interval + grace) * 3600 ))
  delta=$(( NOW_EPOCH - last_epoch ))
  if [ "$delta" -gt "$limit_seconds" ]; then
    delta_h=$(( delta / 3600 ))
    limit_h=$(( limit_seconds / 3600 ))
    ALERTS+=("STALE: $peer (last ${delta_h}h ago, limit ${limit_h}h)")
  fi
done

# ----- 3. Alert if any stale -------------------------------------------------
if [ "${#ALERTS[@]}" -gt 0 ]; then
  MSG="Cron patrol from [$SELF] @ $NOW_ISO"$'\n'
  for a in "${ALERTS[@]}"; do MSG+="$a"$'\n'; done
  echo "$MSG"
  mkdir -p "$(dirname "$ALERT_LOG")"
  echo "$MSG" >> "$ALERT_LOG"

  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    PROXY_OPT=()
    [ -n "${TELEGRAM_PROXY:-}" ] && PROXY_OPT=(-x "$TELEGRAM_PROXY")
    if curl -fsS "${PROXY_OPT[@]}" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$MSG" \
        -o /dev/null; then
      echo "Alert pushed to Telegram chat ${TELEGRAM_CHAT_ID}."
    else
      echo "Telegram send failed; alert logged only." >&2
    fi
  else
    # Name the missing setting(s) so a half-filled alert config is easy to spot.
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
      missing="TELEGRAM_CHAT_ID"
    elif [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
      missing="TELEGRAM_BOT_TOKEN"
    else
      missing="TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID"
    fi
    echo "No $missing configured; alert logged only." >&2
  fi
fi
exit 0
