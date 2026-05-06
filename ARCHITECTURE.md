# Architecture

The architecture has **four agent roles** plus **one human (the operator)**. Each role has a single job and a clear set of things it cannot do. Every role writes to disk in a way the others (and Claude Code, in a rescue scenario) can read.

Rule of thumb: **if you can't tell from a directory listing what each role is doing, the deployment has gone wrong.**

```
                        Operator (human, Principal)
                         │
                         │  CLI, SSH, Telegram bots
                         ▼
              ┌────────────────────────┐
              │  OpenClaw main agent   │  router + side-effect outlet
              │  ~/.openclaw/workspace │
              └─┬──────────────────────┘
                │ spawns + governs
                ▼
   ┌─────────────────────────────────────────────────────┐
   │ OpenClaw workspace subagents                         │
   │ ─────────────────────────────────────────────────── │
   │ <project subagents — your project's domain>          │
   │ hermes-maintainer (~/hermes-maintainer/.openclaw-ws/) │
   └────────────────────┬────────────────────────────────┘
                        │ "hermes-maintainer" reads/runs:
                        ▼
              ┌────────────────────────┐
              │  Hermes Agent          │  evolves OpenClaw
              │  profile:              │
              │  openclaw-evolution    │
              │  ~/.hermes/            │
              └────────────────────────┘
```

## Roles

### Operator (Principal)

The human. Ultimate authority. The architecture exists to *not* require the operator to babysit; it preserves the operator's ability to walk in cold and understand state, but does not require it.

**Cannot:** N/A — the operator can do anything, but the architecture is designed so they don't have to do most of it.

### OpenClaw main agent

**Job:** Route requests. Manage host-level concerns. Apply Hermes-produced upgrade packs after verification. Write the evolution journal. Govern subagents.

**Cannot:** Modify files matching `immutable_paths` in `baseline.policy.yaml`. Modify the watcher unit or its policy. Modify Hermes's source install except by running the documented `hermes update` flow.

### Workspace subagents

Each manages its own project directory. They own everything inside their project, may use `MACHINE_MAP.md` to coordinate on shared infra, and notify main for cross-project work.

This template adds **one** workspace subagent: `hermes-maintainer`. Your project subagents (e.g., `web-app`, `worker`) are out of scope for this template — register them yourself via `openclaw agents add`.

#### hermes-maintainer

**Owns:** `~/hermes-maintainer/.openclaw-ws/` — its own workspace dir. Acts on `~/.hermes/` only via the documented `hermes` CLI.

**Allowed:**
- Run `hermes doctor`, `hermes status`, `hermes -p openclaw-evolution insights --days N`
- Read `~/.hermes/sessions/`, memories, skills, config (read-only)
- Read upstream Hermes repo to track releases
- Write study notes to `~/hermes-maintainer/.openclaw-ws/study-notes/`
- Notify main agent via journal when Hermes needs attention

**Cannot:** Edit Hermes's SOUL.md / USER.md / MEMORY.md (those are Hermes's own state). Modify `~/.hermes/.env` (operator only). Apply Hermes-produced upgrade packs (only main may, after verification). Modify the baseline or watcher.

### Hermes Agent (profile: `openclaw-evolution`)

**Job:** Long-term study of OpenClaw upstream. Read commits, issues, release notes. Maintain a deepening model of what was customized locally and why. Produce upgrade-packs when an OpenClaw release would be valuable to apply. Use its self-improvement loop to get better at this *one* job over time.

**Allowed:**
- Read `~/.openclaw/` (read-only)
- Read upstream OpenClaw repo
- Write to its own `~/.hermes/` profile dir (sessions, memory, skills, SOUL)
- Produce upgrade-pack artifacts in `~/.openclaw/workspace/upgrade-packs/inbox/`
- Talk to operator via CLI, optionally via Telegram (Phase 2)

**Cannot:** Write to `~/.openclaw/` directly except via the inbox. Apply its own upgrade-packs. Modify `~/.hermes/.env`. Modify the watcher or baseline policy. Spawn shell processes outside its sandbox.

## Communication contracts

Roles do **not** chat with each other. They communicate by writing structured files that the others read. No agent-to-agent prompt-passing, no live RPC, no negotiation.

| From → To | Channel | Format |
|---|---|---|
| Hermes → main | Upgrade-pack drop dir | `manifest.yaml` + diffs |
| main → Hermes | Evolution journal entries | append-only JSONL |
| hermes-maintainer → main | Study notes + journal entries | markdown + JSONL |
| Any subagent → main | `MACHINE_LOG.md` updates after touching shared infra | markdown |
| Operator → any | CLI / Telegram / SSH | conversational |

## The hard baseline

`~/.openclaw/workspace/baseline/` contains four files plus two integrity hashes:

- `baseline.policy.yaml` — `forbidden_actions`, `immutable_paths`, `allow_write_for_main`, `change_budget`, `require_approval`
- `hermes-permissions.yaml` — what Hermes may/may-not do
- `machine-mission.md` — what this host is for
- `watcher.sh` — periodic sentinel
- `.expected-hashes` — sha256 of the four files above
- `.expected-hashes.sha256` — meta-hash, sha256 of `.expected-hashes` itself (closes the chicken-and-egg of self-referencing)

All six are `chattr +i` (immutable) after deploy. Modifying them requires `sudo chattr -i` first — and `chattr -i` requires sudo, which agents don't have. Operator edits go through `scripts/edit-baseline.sh`.

## The watcher

A pure-bash systemd user unit firing every 60 seconds. It checks:
- All baseline files still have `chattr +i`
- All sha256 hashes match `.expected-hashes`
- The meta-hash of `.expected-hashes` matches `.expected-hashes.sha256`
- `openclaw-gateway` process is running

Anomalies emit JSONL events to `evolution-journal.jsonl`. The watcher does not act on anomalies — it just records them. The main agent (or operator on next visit) reads and decides.

The watcher is rule-based, not LLM-based. It cannot be talked into anything.

## The cross-patrol heartbeat (Phase 2.5)

Five scheduled jobs run regularly:
- `hermes_daily_doctor` (maintainer, 04:30 local daily)
- `hermes_upstream_watch` (maintainer, 05:00 local daily)
- `hermes_weekly_review` (maintainer, 05:00 local Mondays)
- `hermes_monthly_compress` (maintainer, 05:30 local 1st of month)
- `openclaw-daily-study` (Hermes-side, 10:00 UTC daily)

Each, on success, writes a heartbeat file with its current timestamp + interval + grace. Then it patrols the four other heartbeats; if any is stale beyond `interval + grace`, it sends a Telegram alert via the configured bot (default: maintainer's `@*_watchbot`).

This is a deterministic dead-man-switch: a healthy system is silent; only a missed run produces an alert. There's no "default broken" alarm to clear — *fresh heartbeat* is the dismissal, and every cron writes one when it succeeds.

The alerter (`heartbeat-patrol`) is pure bash, deterministic, with a hard-coded job catalog. If you add a new cron, add it to the catalog in `lib/heartbeat-patrol.sh` (and re-deploy via `scripts/06-cron-setup.sh`).

## What lives where on disk

See [README.md](README.md) for the canonical list.

## Why this division

The four-role split lets the operator walk away. Each role's footprint is in plain markdown / JSONL / YAML — readable by humans, by future Claude Code rescues, and by other agents in the system. No proprietary state.

The hard baseline + watcher means nothing the LLM agents do can take down its own observation channel: the watcher reads `chattr +i` files (cannot be tampered with at the agent level); it writes append-only JSONL (cannot be silenced by truncation without leaving a hash mismatch); it runs as a systemd unit (cannot be stopped without sudo).

The cross-patrol heartbeat means that a stuck cron also surfaces — not just a broken file. A genuinely broken host (both agents asleep) is the only failure mode the patrol misses; the watcher's gateway-up check covers that.
