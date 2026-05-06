# Rollback / uninstall

How to undo what `openclaw-hermes-watcher` installed. This does not uninstall OpenClaw itself — that's the upstream OpenClaw project's responsibility.

## What gets installed

Roughly:

| Path | Created by |
|---|---|
| `~/.openclaw/workspace/baseline/` (chattr +i) | scripts/02 |
| `~/.openclaw/workspace/heartbeats/` | scripts/06 |
| `~/.openclaw/workspace/upgrade-packs/inbox/` | scripts/02 |
| `~/.openclaw/workspace/openclaw-local-diff.md` | scripts/02 |
| `~/.config/systemd/user/openclaw-watcher.service` | scripts/02 |
| `~/.hermes/` (Hermes Agent + profile state) | scripts/03 + scripts/04 |
| `~/hermes-maintainer/.openclaw-ws/` | scripts/05 |
| `~/.local/bin/heartbeat-patrol` | scripts/06 |
| `~/.config/heartbeat-patrol.env` | scripts/06 |
| `~/.local/bin/talk-*` symlinks | scripts/09 |
| OpenClaw cron jobs `hermes_*` | scripts/06 |
| Hermes cron job `openclaw-daily-study` | scripts/06 |
| (Phase 2 only) `hermes-gateway-openclaw-evolution.service` | scripts/11 |

## Uninstall sequence

```bash
# 1. Stop services
systemctl --user stop openclaw-watcher hermes-gateway-openclaw-evolution.service 2>/dev/null
systemctl --user disable openclaw-watcher hermes-gateway-openclaw-evolution.service 2>/dev/null
rm -f ~/.config/systemd/user/openclaw-watcher.service
rm -f ~/.config/systemd/user/hermes-gateway-openclaw-evolution.service
systemctl --user daemon-reload

# 2. Remove cron jobs
for j in hermes_daily_doctor hermes_upstream_watch hermes_weekly_review hermes_monthly_compress; do
    id=$(openclaw cron list --json 2>/dev/null | jq -r --arg n "$j" '.jobs[]? | select(.name == $n) | .id')
    [ -n "$id" ] && openclaw cron rm "$id"
done
hermes -p openclaw-evolution cron list 2>/dev/null | grep -oE '[0-9a-f]{12}' | head -1 | \
    xargs -r hermes -p openclaw-evolution cron rm

# 3. Unregister maintainer subagent
openclaw agents rm hermes-maintainer 2>/dev/null

# 4. Remove Hermes profile (keeps Hermes binary; reinstall safe)
hermes profile rm openclaw-evolution 2>/dev/null

# 5. Unfreeze + remove baseline
sudo chattr -R -i ~/.openclaw/workspace/baseline
rm -rf ~/.openclaw/workspace/baseline

# 6. Optional: remove heartbeats + inbox (low value, but cleans state)
rm -rf ~/.openclaw/workspace/heartbeats
rm -rf ~/.openclaw/workspace/upgrade-packs
rm -f  ~/.openclaw/workspace/openclaw-local-diff.md

# 7. Optional: remove maintainer workspace
rm -rf ~/hermes-maintainer

# 8. Optional: remove heartbeat-patrol script + alert config
rm -f ~/.local/bin/heartbeat-patrol
rm -f ~/.config/heartbeat-patrol.env

# 9. Optional: remove talk-* shortcuts
rm -f ~/.local/bin/talk-*
rm -rf ~/.local/share/openclaw-talk-helpers

# 10. Optional: uninstall Hermes entirely (separate step — not from this template)
#     hermes uninstall  # if available, or manual removal of ~/.hermes/
```

After step 10 you've removed everything this template installed. The OpenClaw main agent and its workspace remain untouched (they were pre-existing).

## Partial rollback

To go back to a specific phase only:

- **Disable Phase 2 (Hermes Telegram):** `systemctl --user stop hermes-gateway-openclaw-evolution.service && systemctl --user disable hermes-gateway-openclaw-evolution.service` and clear `messaging.telegram.enabled` in Hermes config.
- **Disable Phase 1.5 (maintainer Telegram):** clear `gateway.telegram.bots.hermes-maintainer.*` in `~/.openclaw/openclaw.json` and restart `openclaw-gateway`.
- **Disable Phase 2.5 (cross-patrol):** there is no `machine.env` knob for this; partial-rollback is manual. Remove `~/.local/bin/heartbeat-patrol` and edit each of the four maintainer cron prompts via `openclaw cron edit <id> --message "<message-without-the-STEP-1-prefix>"` to drop the heartbeat-patrol invocation. The script's prefix is added by `scripts/06-cron-setup.sh` only when re-running the install — if you re-run it after manual prompt edits, the prefix comes back. To make the change permanent, fork the template and remove `heartbeat_prefix_for` calls from `scripts/06-cron-setup.sh`.
