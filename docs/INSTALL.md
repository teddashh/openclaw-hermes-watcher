# Install guide

Step-by-step walkthrough of installing this template on a host that already has OpenClaw running.

## 1. Pre-requisites

- OpenClaw installed and running (`openclaw status` is happy)
- OpenClaw main agent workspace bootstrapped at `~/.openclaw/workspace/`
- `gh auth login` completed
- bash 4+, jq, curl, envsubst, sha256sum, lsattr/chattr, systemd --user (with linger enabled)
- Optional: Telegram bot tokens via @BotFather (only if you want Phase 1.5 / Phase 2)

## 2. Clone the repo

```bash
git clone https://github.com/<your-fork>/openclaw-hermes-watcher
cd openclaw-hermes-watcher
```

For long-term updates: clone YOUR fork, set the canonical template repo as `upstream`:

```bash
git remote add upstream https://github.com/teddashh/openclaw-hermes-watcher
```

When new releases come out, `git pull upstream main`, resolve any conflicts in your `config/machine.env` (it should be gitignored from upstream so usually no conflicts), then re-run `scripts/all.sh`.

## 3. Configure

There are TWO config files:

```bash
# Non-secret values (operator identity, machine name, bot usernames, schedule).
# Intended to be committed to YOUR private fork.
cp config/machine.env.example config/machine.env
$EDITOR config/machine.env

# Bot tokens (the actual credentials).
# GITIGNORED — never commit, not even to a private fork. Lives only on the
# machine where it's installed.
cp config/machine.env.secrets.example config/machine.env.secrets
$EDITOR config/machine.env.secrets
```

`machine.env` required fields:

- `OPERATOR_NAME`, `OPERATOR_HANDLE`, `OPERATOR_EMAIL` — how agents address you
- `MACHINE_NAME`, `MACHINE_ROLE` — what this host is for
- `MACHINE_SERVICES_MD`, `MACHINE_OUT_OF_SCOPE_MD` — Markdown bullet lists for `machine-mission.md`

`machine.env` optional but recommended:

- `OPERATOR_TELEGRAM_USER_ID` (get yours from `@userinfobot`) — needed for any Telegram phases
- `TG_BOT_*_NAME` — bot usernames (the @handle), one per agent

`machine.env.secrets` (optional per phase):

- `TG_BOT_MAIN_TOKEN` — leave empty to skip the main-agent Telegram bot
- `TG_BOT_HERMES_MAINTAINER_TOKEN` — Phase 1.5
- `TG_BOT_HERMES_AGENT_TOKEN` — Phase 2
- `TG_BOT_PROJECT_SUBAGENT_TOKENS` — comma-sep, same order as `TG_BOT_PROJECT_SUBAGENT_NAMES` in `machine.env`

Leave token fields empty for phases you don't want. The install scripts gate on token presence and skip cleanly.

### Creating Telegram bots

1. Open Telegram, message @BotFather
2. Send `/newbot`
3. Follow prompts (display name + bot username; username must end in `bot` or `_bot`)
4. BotFather replies with a token like `1234567890:ABCdef...`
5. Paste the token into the appropriate `TG_BOT_*_TOKEN` field
6. Paste the bot username (without the `@`) into the `TG_BOT_*_NAME` field

## 4. Install

```bash
bash scripts/all.sh
```

This runs steps 00–11 in order. Each step is idempotent — safe to re-run after editing `machine.env` or fixing an error. The Hermes installer (step 03) takes 10–20 minutes the first time (Python 3.11 install + extension build).

## 5. Verify

```bash
bash scripts/07-smoke-test.sh
```

If anything fails, the script prints what's missing. Common issues:

- `openclaw status not OK` — run `openclaw doctor`
- `hermes doctor reports issues` — usually missing API keys; see [Phase 2 setup](PHASE-2-TELEGRAM.md)
- `gh CLI authenticated` failing — run `gh auth login` interactively

## 6. Pair Telegram bots (Phase 1.5+)

After the install, if you set Telegram bot tokens, you need to authorize your Telegram user ID with each bot:

1. Open Telegram, message your bot (e.g., `@your_watchbot`)
2. Send any text — OpenClaw replies with a pairing code
3. Send the pairing code back to grant scopes

For Hermes (Phase 2): same flow, but message `@your_hermesbot`. Hermes will reply directly.

## 7. What runs when

| Cron | Default schedule | Action |
|---|---|---|
| `hermes_daily_doctor` | 04:30 local | `hermes doctor` + log + heartbeat-patrol |
| `hermes_upstream_watch` | 05:00 local | check Hermes upstream + heartbeat-patrol |
| `hermes_weekly_review` | Mon 05:00 local | `insights --days 7` + summary regen + heartbeat-patrol |
| `hermes_monthly_compress` | 1st 05:30 local | `/compress` session memory |
| `openclaw-daily-study` | 10:00 UTC | Hermes rotating-focus daily study |

You can change the cron expressions in `config/machine.env` and re-run `scripts/06-cron-setup.sh`.

## 8. Updating

When the template gets a new release:

```bash
git fetch upstream
git pull upstream main
bash scripts/all.sh   # re-runs all steps idempotently
```

## 9. Uninstalling

See [ROLLBACK.md](ROLLBACK.md).
