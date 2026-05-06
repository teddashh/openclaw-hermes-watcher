# Phase 2 — Hermes Agent's own Telegram gateway

Phase 2 lets you chat with the Hermes Agent directly via Telegram, separate from OpenClaw's bots. This is opt-in.

## Why it's separate from OpenClaw's bots

OpenClaw has its own Telegram gateway with one bot per agent (Phase 1.5 adds one for the maintainer subagent). Hermes Agent is a different runtime — its own daemon, its own session DB. Phase 2 is where Hermes gets its own bot.

The split matters because:

- **Provenance.** When Hermes replies, it's clear it's *Hermes* talking, not the maintainer. Different bot username = different "voice" in your Telegram client.
- **Authority.** Hermes by SOUL contract does not push autonomously. Its bot is for two-way chat (you ask, it answers). The maintainer's bot is for cross-patrol alerts (Phase 2.5). Different concerns, different bots.
- **Failure isolation.** If Hermes's gateway crashes, the maintainer's bot still works (and vice versa).

## Pre-conditions

- You've completed Phase 1 install (`scripts/all.sh` through 08-finalize).
- You've run Hermes for at least a few days (recommended — lets you confirm the system is stable before adding gateway surface).
- You have a fresh Telegram bot from @BotFather (see [INSTALL.md §3](INSTALL.md) for the @BotFather flow).

## Enable

1. Edit `config/machine.env`:

   ```
   TG_BOT_HERMES_AGENT_TOKEN="1234567890:ABCdef..."
   TG_BOT_HERMES_AGENT_NAME="your_hermesbot"
   ```

2. Run:

   ```bash
   bash scripts/11-tg-hermes.sh
   ```

3. Open Telegram, message your bot. Hermes should reply.

## What changes

- `messaging.telegram.enabled` flips to `true` in the Hermes profile config.
- A new systemd user unit `hermes-gateway-openclaw-evolution.service` is created and started.
- The Hermes profile's `messaging.telegram.allowed_user_id` is set to your `OPERATOR_TELEGRAM_USER_ID` (so random people can't use the bot).

## What does NOT change

- Hermes still does NOT push autonomously. Only the cross-patrol heartbeat-patrol (a separate deterministic script) sends Telegram alerts on stale peers, and those go to the maintainer's bot, not Hermes's.
- Hermes's SOUL contract is unchanged: the gateway is for replies, not for "Hermes thought of something" pings.

## Disable

To roll back Phase 2 only:

```bash
systemctl --user stop hermes-gateway-openclaw-evolution.service
systemctl --user disable hermes-gateway-openclaw-evolution.service
hermes -p openclaw-evolution config set messaging.telegram.enabled false
```

The bot itself stays valid — you can re-enable later by re-running `scripts/11-tg-hermes.sh`.

## Why we wait

The original deployment that this template was extracted from waited 7 days between Phase 1 and Phase 2 to verify nothing was off. The author skipped that wait because Phase 1 was clearly stable. You should make your own call — for "I just installed, everything looks happy" → enable. For "I'm trying this out cautiously" → wait.
