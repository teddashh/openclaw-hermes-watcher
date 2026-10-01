# openclaw-hermes-watcher

[![test](https://github.com/teddashh/openclaw-hermes-watcher/actions/workflows/test.yml/badge.svg)](https://github.com/teddashh/openclaw-hermes-watcher/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/tag/teddashh/openclaw-hermes-watcher?label=release&sort=semver)](https://github.com/teddashh/openclaw-hermes-watcher/releases)

**English** · [繁體中文](README.zh-TW.md)

A drop-in layer for an existing OpenClaw host that adds a Hermes study agent, a guardian subagent, a `chattr +i` policy baseline, and a cross-patrol heartbeat, without modifying OpenClaw or Hermes code.

**Project page:** https://teddashh.github.io/openclaw-hermes-watcher/

> ## Manage the machine with OpenClaw's discipline.
> ## Manage its evolution with Hermes's diligence.
> ### Two agents, helping each other.

This repo is a **layer** on top of an existing [OpenClaw](https://docs.openclaw.ai) host. It adds a focused [Hermes Agent](https://github.com/NousResearch/hermes-agent) profile that studies how OpenClaw on this host should evolve, a guardian subagent that looks after the Hermes install, a `chattr +i` policy baseline that agents cannot rewrite without sudo, and a deterministic cross-patrol heartbeat that surfaces missed jobs the agents themselves would not report. **It does not modify OpenClaw's or Hermes's installed code.** Integration goes through their public CLIs and conventional file locations only, so `openclaw upgrade` and `hermes update` are unaffected.

Apache-2.0. Latest release: v0.1.7 (2026-05-07). There have been no commits on `main` since then; read [§10 Known Limitations](#10-known-limitations) before installing, especially on OpenClaw 2026.5.20 or later.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [The Problem This Solves](#2-the-problem-this-solves)
3. [Architecture: Why Each Layer Exists](#3-architecture-why-each-layer-exists)
   - 3.1 [The four roles](#31-the-four-roles)
   - 3.2 [The file contract](#32-the-file-contract)
   - 3.3 [The hard baseline](#33-the-hard-baseline-chattr-i--sha256--meta-hash)
   - 3.4 [The watcher](#34-the-watcher-deterministic-bash-not-an-llm)
   - 3.5 [The cross-patrol heartbeat](#35-the-cross-patrol-heartbeat-phase-25)
   - 3.6 [How we address the six known-hard problems](#36-how-we-address-the-six-known-hard-problems)
4. [Implementation Walk-through](#4-implementation-walk-through)
   - 4.1 [Repository layout](#41-repository-layout)
   - 4.2 [Phase 1: install](#42-phase-1-install-hermes-maintainer-baseline-watcher)
   - 4.3 [Phase 1.5: talk-helpers and maintainer Telegram](#43-phase-15-talk-helpers-and-maintainer-telegram)
   - 4.4 [Phase 2: Hermes Telegram gateway](#44-phase-2-hermes-telegram-gateway)
   - 4.5 [Phase 2.5: daily cron and heartbeat](#45-phase-25-daily-cron-and-cross-patrol-heartbeat)
5. [Pre-conditions](#5-pre-conditions)
6. [What Lives Where](#6-what-lives-where-after-install)
7. [Daily Operations](#7-daily-operations)
8. [Long-term Maintenance](#8-long-term-maintenance)
9. [Lessons Baked In](#9-lessons-baked-in)
10. [Known Limitations](#10-known-limitations)
11. [License](#11-license)

---

## 1. Quick Start

You already have OpenClaw running. You want a long-running Hermes agent, a guardian, and a dead-man's switch on top. Five commands:

```bash
git clone https://github.com/teddashh/openclaw-hermes-watcher   # or your fork, see docs/INSTALL.md
cd openclaw-hermes-watcher
cp config/machine.env.example config/machine.env
$EDITOR config/machine.env             # operator, machine, services, schedule (no secrets here)
bash scripts/all.sh                    # idempotent end-to-end install
```

Bot tokens are optional and live in a separate file that git ignores: `cp config/machine.env.secrets.example config/machine.env.secrets`, then fill in only the bots you want. Without tokens, the Telegram phases are skipped.

`all.sh` asks for sudo (to set `chattr +i`), and the first Hermes install takes 10 to 20 minutes. It runs the smoke test (`bash scripts/07-smoke-test.sh`) as step 07; re-run it any time. From then on Hermes wakes daily, picks a study task by weekday, and writes its findings to files. The four maintainer jobs and the Hermes job check each other's heartbeats, and an alert goes out only when a job misses its window. See [§7 Daily Operations](#7-daily-operations) for what a normal day looks like.

If you want to understand why the architecture is shaped this way before you commit, read on. Sections 2 to 4 are the long explanation.

---

## 2. The Problem This Solves

You run an OpenClaw deployment. The router is up, the workspace is bootstrapped, your project subagents are registered, the Telegram bots are paired. Life is good. Now you want a long-running agent that watches OpenClaw upstream (reads commits and issues, keeps a model of your local diffs, drafts upgrade-packs when a release is worth applying) without you babysitting it daily, and without giving it enough rope to talk itself into things you didn't authorize.

The naive approaches fail in specific, predictable ways:

### 2.1 "Just run a daily cron that diffs upstream and pings me on Slack."

- One month in, you've started ignoring the pings. **Approval fatigue.**
- Three months in, you've drifted six minor versions behind. The first ping you actually read says "23 commits, 4 breaking", which is too much to evaluate at once.
- The cron knows nothing about your local diffs. Its breaking-change list is a superset of the things that actually break here. You stop trusting the noise.

### 2.2 "Give Claude Code (or another general agent) the task ad-hoc."

- Each session starts cold. No accumulated model of "why did we customize file X three months ago?"
- Each session has a different opinion on what's worth applying. **Taste drift** between sessions.
- You pay to rebuild context every time. The cost compounds.

### 2.3 "Let the agent self-update without supervision."

- It works until the day it doesn't. A bad upgrade with no rollback path is hard to recover from a single shell.
- The agent has no incentive to preserve your local diffs; its incentive is to land the upgrade.
- The first thing a misaligned agent learns to do is silence the alert that would have caught it.

### 2.4 What this template does instead

- **A long-running agent (Hermes)** grows over weeks and months into a focused expert on **how this host's OpenClaw should evolve to serve the operator's services better**. Its accumulated model lives in `~/.hermes/memories/MEMORY.md` and `~/.hermes/skills/`, so it does not start cold. It draws from four food sources in priority order: service signals (each subagent's MACHINE_LOG, the primary food, because service health is the only fitness function), upstream OpenClaw, the community ecosystem (high-star OpenClaw skill and plugin repos), and its own accumulated memory.
- **A guardian subagent (`hermes-maintainer`)** runs scheduled checks on Hermes itself: `hermes doctor`, a weekly insights review, a monthly compress, and an upstream release watch. It cannot apply packs or run `hermes update`. It flags; the operator decides.
- **A hard baseline (`chattr +i` policy files)** encodes what agents must not do, however convincing a future proposal is. Rewriting it takes `sudo chattr -i` first, and agents are not supposed to have sudo (read the caveat in [§3.3](#33-the-hard-baseline-chattr-i--sha256--meta-hash)).
- **A watcher (about 200 lines of bash in a systemd user unit)** checks the baseline every 60 seconds. It is rule-based code, not an LLM, so there is nothing to argue with.
- **A cross-patrol heartbeat** means Telegram only alerts you when a scheduled job misses its window. Healthy operation is silent.

The result is a system you can mostly leave alone. You check in once a month, glance at `~/.openclaw/workspace/evolution-journal.jsonl`, see what Hermes has been studying, and review any pack that needs you. Otherwise, silence.

---

## 3. Architecture: Why Each Layer Exists

**Integration boundary first.** This template is a layer that integrates with OpenClaw and Hermes through their public CLIs (`openclaw cron / agents / config`, `hermes profile / config / cron / gateway`) and conventional file locations (`~/.openclaw/workspace/`, `~/.hermes/profiles/<name>/`). It **never modifies** their installed code:

| Path | Touched by this template? |
|---|---|
| `/usr/lib/node_modules/openclaw/` (OpenClaw installed code) | **No.** Listed in `baseline.policy.yaml` `immutable_paths` |
| `~/.hermes/hermes-agent/` (Hermes installed code) | **No.** Changed only by `hermes update`, which the operator runs |
| `~/.openclaw/openclaw.json` (OpenClaw main config) | **No direct write.** Changes go through the `openclaw` CLI (for example `openclaw config set`) |
| `~/.openclaw/workspace/baseline/` (this template's policy files) | Yes. `chattr +i` after deploy, operator-only edits |
| `~/.hermes/profiles/openclaw-evolution/` (one Hermes profile) | Yes. Hermes's documented profile mechanism |
| `~/hermes-maintainer/.openclaw-ws/` (subagent workspace) | Yes. OpenClaw's documented subagent mechanism |

The full file inventory is in [§6 What Lives Where](#6-what-lives-where-after-install). Practical consequence: `openclaw upgrade` and an operator-run `hermes update` go through without touching anything this template puts on disk.

**The same layer-only commitment shapes what Hermes is allowed to propose.** Hermes's evolution-packs come in five `pack_kind`s, defined in `baseline.policy.yaml` `pack_kinds`. The two safest, `install_skill` and `install_plugin`, drop into OpenClaw's documented extension points (`~/.openclaw/skills/` and the plugin system) and **structurally cannot modify OpenClaw itself**. That is why one of Hermes's four food sources is the community ecosystem (high-star skill and plugin repos such as `VoltAgent/awesome-openclaw-skills`): adopting a community skill that solves a service pain is the most layer-friendly move Hermes can make. The policy lets main apply those two kinds and `apply_upstream_patch` after verification, inside the maintenance window and the weekly change budget. `synthesize_custom` and `config_change` always wait for operator review.

Each layer below earns its space: what it does, why it is needed, and which failure mode it addresses. The architecture takes explicit positions on six known-hard problems that any design for a long-running agent on a production host has to answer (see [§3.6](#36-how-we-address-the-six-known-hard-problems)).

### 3.1 The four roles

The architecture has four agent roles plus one human:

```
                        Operator (human, Principal)
                         │
                         │  CLI · SSH · Telegram bots
                         ▼
              ┌────────────────────────┐
              │  OpenClaw main agent   │  router + side-effect outlet
              │  ~/.openclaw/workspace │
              └─┬──────────────────────┘
                │ spawns + governs
                ▼
   ┌───────────────────────────────────────────────────────┐
   │ OpenClaw workspace subagents                          │
   │ ───────────────────────────────────────────────────── │
   │ <your project subagents: out of scope for this repo>  │
   │ hermes-maintainer (~/hermes-maintainer/.openclaw-ws/) │
   └────────────────────┬──────────────────────────────────┘
                        │ "hermes-maintainer" reads/runs:
                        ▼
              ┌────────────────────────┐
              │  Hermes Agent          │  evolves OpenClaw
              │  profile:              │
              │  openclaw-evolution    │
              │  ~/.hermes/            │
              └────────────────────────┘
```

**Rule of thumb: if you can't tell from a directory listing what each role is doing, the deployment has gone wrong.** Everything the roles use to coordinate is plain markdown, JSONL, or YAML, readable by humans, by a later Claude Code rescue session, and by the other agents. Hermes keeps its own session history in its SQLite store, but nothing in the coordination path depends on it.

**Enforcement note.** All agents run as the Linux user that ran the installer. The hard guarantees are the `chattr +i` files (changing them needs root) and Hermes's own shell sandbox. The rest of the "Cannot" lists below are policy: written into `baseline.policy.yaml` and `hermes-permissions.yaml`, read by the agents, and checked by main before it applies a pack.

#### 3.1.1 Operator (Principal)

The human, and the final authority. The architecture is built so you do not have to babysit it; you can walk in cold and understand the state, but you are not required to.

You communicate with the agents via:
- CLI (`talk-main`, `talk-maintainer`, `talk-hermes`, from Phase 1.5)
- Telegram bots (one per agent, opt-in in Phase 1.5 and Phase 2)
- SSH and direct file edits (always available)

You hold authority that no agent has:
- `sudo chattr -i`: only you can unfreeze the baseline (through `scripts/edit-baseline.sh`)
- `hermes update`: only you decide when to upgrade Hermes (the maintainer flags releases, you act)
- High-risk packs: `synthesize_custom` and `config_change` packs, and anything in the `high_risk` tier, wait for your approval. Main may apply low-risk and medium-risk packs after verification, within the change budget in `hermes-permissions.yaml` and the maintenance window in `machine-mission.md` (04:00 to 06:00 in `TZ_NAME` from `machine.env`; low-risk packs may also apply outside it).

#### 3.1.2 OpenClaw main agent

**Job:** Route requests. Handle host-level concerns (Caddy, Docker, systemd, ports, SSL, backups). Verify Hermes-produced packs and apply the ones the policy allows. Write to the evolution journal. Govern subagents.

**Cannot:** Modify files under `immutable_paths` in `baseline.policy.yaml`. Modify the watcher script or the policy files (`chattr +i`). Stop or edit the watcher unit (policy only: `disable_watcher` has no detector yet, see [§10](#10-known-limitations)). Modify Hermes's source install (`~/.hermes/hermes-agent/`); upgrades go through `hermes update`, which the operator runs.

**Footprint:** `~/.openclaw/workspace/MACHINE_LOG.md`, `evolution-journal.jsonl`, `DEVIATIONS.md`.

#### 3.1.3 hermes-maintainer subagent

A workspace subagent whose only job is to keep the local Hermes Agent install healthy, current, and on task. **Hermes's medic and archivist, not its boss.**

**Allowed:**
- Run `hermes doctor`, `hermes status`, `hermes -p openclaw-evolution insights --days N`
- Read `~/.hermes/sessions/`, memories, and skills (read-only)
- Read the upstream Hermes repo to track releases
- Write study notes to `~/hermes-maintainer/.openclaw-ws/study-notes/`
- Write journal events for main and the operator (for example `hermes_proposed`, `hermes_release_review_pending`)

**Cannot:**
- Edit Hermes's SOUL.md, USER.md, or MEMORY.md (those are Hermes's own state)
- Modify `~/.hermes/.env` (API keys, operator only)
- Apply Hermes-produced packs (only main may, after verification)
- Modify the baseline or the watcher
- Run `hermes update` on its own. It is listed under `forbidden_autonomous` in `hermes-permissions.yaml`; the maintainer writes a journal event and the operator decides.

**Why it is separate from main:** its daily and weekly cadence is dedicated to Hermes-related signals, so it does not compete with main's host-management work. Its bootstrap files (`AGENTS.md`, `IDENTITY.md`) keep it anchored to the narrow role even when the operator hasn't visited in weeks.

#### 3.1.4 Hermes Agent (`openclaw-evolution` profile)

**Job:** Evolve OpenClaw on this host so it serves the operator's services better. Read each service's MACHINE_LOG to find pain points; cross-reference upstream OpenClaw, the community ecosystem (high-star skill and plugin repos), and accumulated MEMORY; draft evolution-packs that target specific service improvements. Its self-improvement loop is pointed at this *one* job. Success metric: service health (stability, latency, error rate, recovery time, ease of upgrade), not upstream conformance.

**Allowed:**
- Read `~/.openclaw/` (read-only), including each service's MACHINE_LOG, the evolution journal, and study notes
- Read the upstream OpenClaw repo through the `gh` CLI, or the REST API as a fallback
- Read the community ecosystem: curator lists such as `VoltAgent/awesome-openclaw-skills`, and `gh search repos --topic openclaw-skill` / `--topic openclaw-plugin`
- Write to its own `~/.hermes/` space (sessions, memories, skills, SOUL, heartbeats)
- Draft evolution-packs in `~/.openclaw/workspace/upgrade-packs/inbox/`. Pack `kind` is one of `install_skill`, `install_plugin`, `apply_upstream_patch`, `synthesize_custom`, `config_change`, defined in `baseline.policy.yaml` `pack_kinds`. The first two only use extension points and are preferred.
- Reply to the operator over the CLI, or over Telegram if Phase 2 is enabled

**Cannot:**
- Write to `~/.openclaw/` directly, except the upgrade-pack inbox
- Apply its own packs
- Modify `~/.hermes/.env`
- Modify the watcher or the baseline policy
- Run shell commands outside its sandbox (Hermes's shell tool is chroot-jailed; see [§9 Lessons Baked In](#9-lessons-baked-in))

### 3.2 The file contract

> **Roles do NOT chat with each other. They communicate by writing structured files that the others read.**

This is the most important architectural rule in the system. No agent-to-agent prompt passing, no live RPC, no negotiation. Each role writes to disk in a format the others (and Claude Code, in a rescue) can read.

| From → To | Channel | Format |
|---|---|---|
| Hermes → main | Upgrade-pack inbox | `manifest.yaml`, `summary.md`, `rollback-plan.md` |
| main → Hermes | Evolution journal entries | append-only JSONL |
| hermes-maintainer → main | Study notes + journal entries | markdown + JSONL |
| watcher → main, operator | Evolution journal entries | append-only JSONL |
| Any subagent → main | `MACHINE_LOG.md` updates | markdown |
| Operator → any | CLI / Telegram / SSH | conversational |

**Why files, not RPC:**

1. **Auditability.** A pack proposal is a file you can `cat`. A journal event is a JSONL line you can `jq`. There is no transient state and no "what did the agents say to each other yesterday" question. If it happened, it's on disk.
2. **Rescue.** When something goes wrong and you SSH in cold, plain markdown, JSONL, and YAML are about the most rescue-friendly formats there are. No daemons to inspect, no network endpoints to query, just files.
3. **Async by default.** The agents don't need to be online at the same time. Hermes drafts a pack during its Thursday 10:00 UTC run and writes `summary.md` on Friday; the maintainer and main pick it up on their own schedules. Each role moves at its own pace.
4. **No agent-to-agent persuasion.** When a pack is ready, the maintainer writes a `hermes_proposed` journal event with the pack ID. Nobody writes prose to convince main. Main reads `manifest.yaml` and decides.
5. **Symmetry with rescue agents.** When you (or Claude Code) walk in to investigate "what's going on with this host", you read the same files the agents do. There's no hidden inter-agent state to recover.

### 3.3 The hard baseline (chattr +i + sha256 + meta-hash)

`~/.openclaw/workspace/baseline/` holds three policy files, the watcher script, and two integrity hashes:

```
baseline/
├── baseline.policy.yaml         # immutable_paths, allow_write_for_main, forbidden_actions, require_approval, pack_kinds, known_good, managed_paths
├── hermes-permissions.yaml      # hermes_may, hermes_may_not, change_budget
├── machine-mission.md           # what this host is for, change budget summary, maintenance window
├── watcher.sh                   # the sentinel script
├── .expected-hashes             # sha256 of the four files above
└── .expected-hashes.sha256      # meta-hash: sha256 of .expected-hashes itself
```

All six are `chattr +i` after deploy. The watcher's systemd unit file is not (see [§3.4](#34-the-watcher-deterministic-bash-not-an-llm)).

**Why chattr +i** (rather than plain file permissions):
- File permissions can be changed by the file's owner. The agents run as the same Linux user that owns the baseline files, so without `chattr +i` any agent could `chmod` them and rewrite them.
- `chattr +i` makes a file immutable at the kernel level. Writing requires `chattr -i` first, and that requires root.
- This is the most load-bearing security property in the system. Without it, every other layer is decorative: an LLM that decides the policy is "outdated" can simply rewrite it.
- **The sudo caveat.** The installer does not configure sudo. `chattr +i` only stops an agent if the Linux user the agents run as cannot use sudo without a password. If that user has passwordless sudo (many cloud images set this up for the default user), any agent with shell access can run `sudo chattr -i` itself, and the baseline becomes a policy rather than a lock. Check `/etc/sudoers` and `/etc/sudoers.d/` for a `NOPASSWD` entry before you rely on it.

**Why a `.expected-hashes` file** (rather than trusting chattr alone):
- chattr +i blocks writes while it is set, but a determined attacker could in principle change the data below the filesystem layer (a raw block-device write, for example). Defense in depth says: verify hashes too.
- More practically: if a file loses its `+i` flag (an interrupted edit, or a manual `chattr -i` that was never undone), the watcher reports `baseline_immutability_lost`, and any content change shows up as `baseline_hash_mismatch`.

**Why a meta-hash** (`.expected-hashes.sha256`):
- This is the chicken-and-egg fix. If `.expected-hashes` itself could be tampered with, an attacker could rewrite a baseline file and its line in `.expected-hashes` in lockstep, defeating the hash check.
- The meta-hash is the sha256 of `.expected-hashes`, stored in a separate file. The watcher verifies the meta-hash before trusting `.expected-hashes`. To beat this, an attacker would need to rewrite three files in lockstep, and any one of them still being `chattr +i` breaks the chain.

**Editing the baseline** is operator-only, through `scripts/edit-baseline.sh <file>`. That script:
1. `sudo chattr -i` on the target and the two hash files
2. Opens the file in `$EDITOR`
3. Regenerates `.expected-hashes` and `.expected-hashes.sha256`
4. `sudo chattr +i` on the target and the two hash files
5. Appends an `operator_edited_baseline` journal event with `actor=operator`

If a file is ever left mutable, the watcher logs `baseline_immutability_lost` on its next pass and repeats it every minute until the flag is back. That holds only while the watcher is running (see [§10](#10-known-limitations)).

Note that re-running `scripts/all.sh` re-renders the baseline from `templates/` and `config/machine.env` and replaces any deployed file that differs. Make lasting baseline changes in your fork's templates or config, not only in the deployed copy.

### 3.4 The watcher (deterministic bash, not an LLM)

A systemd user unit at `~/.config/systemd/user/openclaw-watcher.service` runs `~/.openclaw/workspace/baseline/watcher.sh` (itself `chattr +i`) as a long-running loop that sleeps 60 seconds between passes (`INTERVAL_SEC=60`). systemd restarts it 30 seconds after a failure.

Every pass, the watcher:
- Checks that every `*.yaml`, `*.md`, and `*.sh` file in the baseline directory, plus the two hash files, still has `chattr +i`
- Checks the meta-hash of `.expected-hashes` against `.expected-hashes.sha256`
- Checks every sha256 in `.expected-hashes`
- Checks that an OpenClaw gateway process is running
- Once an hour, writes a `watcher_heartbeat` event so you can see the watcher itself is alive

Anomalies become JSONL events in `~/.openclaw/workspace/evolution-journal.jsonl`. The watcher does not act on anomalies and does not send Telegram messages; it only records them. Main, or the operator on the next visit, reads and decides.

**Why pure bash, not an LLM:**
- An LLM watcher can be argued with: "this file change is fine because X." A rule-based watcher cannot. It computes a hash, compares it to a fingerprint, and writes a JSONL event on a mismatch. There's nothing to negotiate with.
- The principle: **a watcher that needs to think can be talked into permitting things; a watcher that is just a write-protected script cannot.**

**Why a systemd user unit, not a system unit:**
- User units don't need root. The watcher runs as the same user as the gateway.
- User units install under `~/.config/systemd/user/` without touching `/etc/systemd/system/`.
- Trade-offs: several hardening options need a system unit and fail in user mode (`LockPersonality`, `MemoryDenyWriteExecute`, `ProtectKernelTunables`, and others), so the unit keeps only `ProtectSystem=strict`, `ReadOnlyPaths`/`ReadWritePaths`, `NoNewPrivileges`, `PrivateTmp`, and `RestrictAddressFamilies`. And because the unit belongs to the agents' user, that user can stop it without sudo. Stopping the watcher is forbidden by policy (`disable_watcher`), not prevented.

**Why the watcher's checks are minimal:**
- Every extra check is one more thing to maintain. The four checks above are the load-bearing ones.
- Changing the watcher is a heavy decision on purpose, because `watcher.sh` is `chattr +i`. To change it for good, edit `lib/watcher.sh` in your fork and re-run `scripts/all.sh`.

### 3.5 The cross-patrol heartbeat (Phase 2.5)

A deterministic dead-man's switch. Instead of "the alarm fires when something breaks", it works as **"the alarm fires unless a fresh heartbeat dismissed it."**

Five scheduled jobs run regularly:

| Job (heartbeat name) | Default schedule | Owner | Stale after |
|---|---|---|---|
| `hermes_daily_doctor` | 04:30 local, daily | hermes-maintainer (OpenClaw cron) | 24h + 6h |
| `hermes_upstream_watch` | 05:00 local, daily | hermes-maintainer (OpenClaw cron) | 24h + 6h |
| `hermes_weekly_review` | 05:00 local, Monday | hermes-maintainer (OpenClaw cron) | 168h + 24h |
| `hermes_monthly_compress` | 05:30 local, 1st of the month | hermes-maintainer (OpenClaw cron) | 720h + 72h |
| `hermes_daily_study` (Hermes job `openclaw-daily-study`) | 10:00 UTC, daily | Hermes Agent (Hermes cron) | 24h + 6h |

"Local" is `TZ_NAME` in `machine.env` (default `America/New_York`). All five schedules are cron expressions you can change there. Hermes's scheduler uses the host's clock, so the daily study runs at 10:00 UTC on a host whose clock is set to UTC (a common cloud default).

Each job, as its **first** step, writes a heartbeat file (timestamp, interval, grace). Then it patrols the other four heartbeats; if any is older than interval + grace, it raises an alert. A heartbeat proves the job fired, not that its task succeeded.

The four maintainer jobs call `~/.local/bin/heartbeat-patrol --self <job>`. On a stale peer, the script appends to `~/.openclaw/workspace/heartbeats/_alerts.log` and, if `~/.config/heartbeat-patrol.env` has both a bot token and a chat ID, sends a Telegram message through the configured proxy. The Hermes job patrols with its own file tools and alerts through its Telegram gateway, or appends to `~/.hermes/heartbeats/_alerts.log` when no chat ID is configured. There is no de-duplication: every job that sees the same stale peer alerts again.

**Why heartbeat FIRST in the cron prompt** (not last):

We learned this the hard way. When the patrol call was a suffix on the agent prompt, the agent would write its summary ("Done. ... I did not run hermes update.") as its final response *before* invoking the patrol script. The OpenClaw cron framework treats the first textual summary as run completion, so the suffix never fired and the heartbeat never landed. Putting `STEP 1: heartbeat-patrol` at the start of the prompt means the heartbeat is written and peers patrolled before the agent produces a final summary, even if later tasks run out of turns or the classifier short-circuits. See `scripts/06-cron-setup.sh` `heartbeat_prefix_for`.

**Why a separate alerter script** (`heartbeat-patrol`):

The patrol logic must be deterministic. If the patrol itself were an LLM call, it would share the alignment failure modes of the agents it patrols. So `heartbeat-patrol` is about 170 lines of bash: it writes a heartbeat, reads the peers, compares now minus the last timestamp against interval + grace, and curls Telegram on staleness. No LLM in the alert path for the maintainer jobs.

**Why "an alert dismissed by a fresh heartbeat" rather than "alarm on failure":**

If the alarm fires on failure, the alarm path itself becomes a single point of failure. Crash the alerter and you get silence. With the heartbeat-as-dismissal pattern, the *absence* of action triggers the alarm, so the failed job doesn't need to be running to alert you: the next still-alive peer's patrol notices the stale heartbeat.

**Why each agent uses its own bot for alerts** (rather than one shared bot):

Different bots are different "voices" in your Telegram client. When the maintainer's bot pings you, a maintainer job detected staleness. When Hermes's bot writes, it's Hermes itself. If something is wrong with one agent, the alert from the other agent's bot still gets through.

**The Hermes-side job is special.** It uses Hermes's own cron scheduler, not OpenClaw cron, because:
- OpenClaw cron with `--session isolated --agent X` runs as an OpenClaw subagent, not as Hermes.
- The daily study writes to Hermes's own state (sessions, memories, skills), and only Hermes has clean write access there.
- Hermes's shell tool is chroot-jailed (more in §9), so the daily-study prompt tells Hermes to use its native file tools with **absolute paths** rather than the patrol script, which lives outside the jail.

### 3.6 How we address the six known-hard problems

Long-running agents on production hosts have to take positions on six known-hard problems. This template doesn't claim to solve them; it takes an explicit stance on each.

| Problem | Stance | Where in the code |
|---|---|---|
| **Cold start**: first-week behavior is qualitatively different | The maintainer's daily-doctor job runs from day 1, so observability doesn't depend on the agent already being trustworthy | `scripts/06-cron-setup.sh` registers the jobs right after install |
| **Recursive upgrade**: the agent updating itself | `hermes update` is `forbidden_autonomous`; the operator runs it | `templates/hermes-permissions.yaml.tmpl` `change_budget.tier_examples.forbidden_autonomous`, `templates/hermes-maintainer-AGENTS.md.tmpl` |
| **Taste drift**: the agent's preferences diverge from the operator's | SOUL.md survives re-runs; the maintainer's weekly review surfaces drift signals | `scripts/04-configure-hermes.sh` writes SOUL.md only if it is missing or still the Hermes installer's generic default |
| **Approval fatigue**: the operator stops reading proposals carefully | Drafts go to the inbox; no autonomous Telegram push; low-risk packs apply within a budget; the operator pulls when curious | `templates/SOUL.md.tmpl` "Output goes to FILES, not Telegram pushes" |
| **Token cost**: the agent's own thinking is expensive | Weekday rotation keeps each day's task narrow; a same-day check skips work already done; the prompt caps a run at 30 minutes or 30 turns (an instruction, not enforced) | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 3 |
| **Fleet sharing**: coordinating across machines | Explicitly out of scope; one host, one config | No fleet logic anywhere |

---

## 4. Implementation Walk-through

Each architectural decision has a corresponding piece of code. This section walks through the install in order and points at the files that implement each layer.

### 4.1 Repository layout

```
openclaw-hermes-watcher/
├── README.md                          ← you are here (English)
├── README.zh-TW.md                    ← 繁體中文
├── ARCHITECTURE.md                    ← shorter architecture doc (this README has the long form)
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE                            ← Apache-2.0
├── .gitignore                         ← machine.env, machine.env.secrets, heartbeat-patrol.env, .pii-patterns.local, .render-cache/
│
├── .github/
│   ├── workflows/test.yml             ← CI: bash -n, PII check, template render smoke test
│   ├── workflows/pages.yml            ← publishes site/ to GitHub Pages
│   ├── ISSUE_TEMPLATE/                ← bug report, feature request
│   └── PULL_REQUEST_TEMPLATE.md
│
├── config/
│   ├── machine.env.example            ← per-machine settings without secrets (operator copies + edits)
│   └── machine.env.secrets.example    ← bot tokens (the real copy is gitignored)
│
├── examples/
│   ├── README.md
│   ├── solo-dev.env                   ← one developer, one machine, no Phase 2
│   └── shared-server.env              ← multi-service host with Phase 1.5 and Phase 2
│
├── lib/                               ← generic shell, ships as-is, no rendering
│   ├── heartbeat-patrol.sh            ← deterministic dead-man's-switch alerter (about 170 lines)
│   └── watcher.sh                     ← baseline sentinel (about 200 lines, 60-second loop)
│
├── templates/                         ← .tmpl files rendered by envsubst with an allowlist
│   ├── machine-mission.md.tmpl        ← what this host is for (chattr +i after deploy)
│   ├── baseline.policy.yaml.tmpl      ← hard floor: immutable_paths, forbidden_actions, pack_kinds, ...
│   ├── hermes-permissions.yaml.tmpl   ← Hermes's allowed and denied scope, change budget
│   ├── SOUL.md.tmpl                   ← Hermes's identity (kept across re-runs after first install)
│   ├── USER.md.tmpl                   ← Hermes's view of the operator
│   ├── MEMORY.md.tmpl                 ← bootstrap for Hermes's accumulated knowledge
│   ├── hermes-daily-study-prompt.txt.tmpl  ← the daily cron prompt (heartbeat first)
│   ├── hermes-maintainer-AGENTS.md.tmpl    ← maintainer subagent's role spec
│   ├── hermes-maintainer-IDENTITY.md.tmpl  ← maintainer's short identity blurb
│   └── openclaw-watcher.service.tmpl       ← systemd user unit
│
├── scripts/                           ← install scripts, run in numbered order
│   ├── 00-prereqs.sh                  ← check tools, OpenClaw, gh auth, workspace, machine.env
│   ├── 01-render.sh                   ← templates/ → .render-cache/ via envsubst
│   ├── 02-deploy-baseline.sh          ← chattr +i baseline, install + start watcher
│   ├── 03-install-hermes.sh           ← curl | bash upstream installer (--skip-setup)
│   ├── 04-configure-hermes.sh         ← create profile, write SOUL/USER/MEMORY
│   ├── 05-register-maintainer.sh      ← register hermes-maintainer OpenClaw subagent
│   ├── 06-cron-setup.sh               ← install heartbeat-patrol + 5 scheduled jobs
│   ├── 07-smoke-test.sh               ← end-to-end verification (41 checks)
│   ├── 08-finalize.sh                 ← summary + next steps
│   ├── 09-talk-helpers.sh             ← Phase 1.5: talk-* ACP shortcut wrappers
│   ├── 10-tg-maintainer.sh            ← Phase 1.5: maintainer's Telegram bot
│   ├── 11-tg-hermes.sh                ← Phase 2: Hermes's own Telegram gateway
│   ├── all.sh                         ← orchestrator (runs 00 to 11 in order)
│   ├── edit-baseline.sh               ← operator-only: safely edit chattr +i files
│   └── lib/
│       ├── common.sh                  ← shared helpers (load_config, emit_journal_event)
│       └── render-template.sh         ← envsubst with an explicit allowlist
│
├── docs/
│   ├── INSTALL.md                     ← step by step
│   ├── PHASE-2-TELEGRAM.md            ← @BotFather flow for Phase 2
│   └── ROLLBACK.md                    ← uninstall sequence
│
├── site/                              ← project page (rendered from site/page.json)
│
└── tests/
    ├── check-no-pii.sh                ← CI guard: no operator literals in committed files
    ├── .pii-patterns.local.example    ← operator-specific pattern template (copy is gitignored)
    └── (.pii-patterns.local, gitignored)
```

### 4.2 Phase 1: install Hermes, maintainer, baseline, watcher

The heart of the install. Order matters and is enforced by file naming (`00-` through `08-`).

**`00-prereqs.sh`** checks that the host is ready:
- bash 4+, jq, curl, envsubst, git, sha256sum, lsattr/chattr, `systemctl --user`
- OpenClaw installed and `openclaw status` happy
- gh CLI authenticated
- `~/.openclaw/workspace/` exists (main agent bootstrap done)
- `config/machine.env` present
- `loginctl` linger enabled, so user services survive logout (a warning only, not a failure)

It fails fast with actionable messages and changes no state.

**`01-render.sh`** renders the templates:
- Loads `config/machine.env` (and `config/machine.env.secrets` if present) through `load_config` in `scripts/lib/common.sh`
- Auto-detects `KNOWN_GOOD_*_VERSION` from installed binaries (or `unknown` if something is not installed yet; step 03 fixes that up)
- Calls `render_template` (in `scripts/lib/render-template.sh`), which wraps `envsubst` with an explicit allowlist of variable names
- Copies `lib/watcher.sh` as-is and fills `__HOME__` and `__MACHINE_NAME__` in the unit file with `sed`
- Writes everything to `.render-cache/` (gitignored)

**Why envsubst with an allowlist** (rather than bare envsubst): bare envsubst substitutes any `$VAR` in the input. Templates legitimately contain `$()` shell snippets and `$VAR` references that should stay literal. The allowlist names exactly which variables get substituted and leaves the rest as text.

**`02-deploy-baseline.sh`** stages the `chattr +i` layer:
1. Checks that `.render-cache/` has all five rendered files
2. If a frozen baseline is already deployed and its content differs from the new render, unfreezes it (`sudo chattr -R -i`)
3. Copies changed files to `~/.openclaw/workspace/baseline/`
4. Regenerates `.expected-hashes` (sha256 of every `*.yaml`, `*.md`, and `watcher.sh`) and the meta-hash `.expected-hashes.sha256` when they no longer match
5. Installs and enables the user unit at `~/.config/systemd/user/openclaw-watcher.service`
6. **`sudo chattr +i`** on the four baseline files and both hash files
7. Starts `openclaw-watcher`
8. Creates `~/.openclaw/workspace/upgrade-packs/inbox/` and `heartbeats/`, and stubs `openclaw-local-diff.md` if missing

If the watcher fails to start, deployment halts: an unenforced baseline is worse than no baseline.

**`03-install-hermes.sh`** runs the upstream Hermes installer:
- If `hermes` is already installed, it reports the version and exits (idempotent skip)
- Otherwise runs `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_INSTALL_REF}/scripts/install.sh | bash -s -- --skip-setup`. `--skip-setup` because step 04 configures the profile; the script never runs `hermes claw migrate`, which would pull OpenClaw's SOUL, memory, skills, and keys into Hermes.
- Warns if `HERMES_INSTALL_REF` is `main` (moving target) and if an `openclaw-imports` skills directory shows up (a sign that a migration ran anyway)
- After a fresh install, **re-runs `01-render.sh` and `02-deploy-baseline.sh --force`** so the real Hermes version replaces the `unknown` that was baked in before Hermes existed on PATH (lesson 6 in §9)

**`04-configure-hermes.sh`** creates the Hermes profile:
- `hermes profile create openclaw-evolution --no-alias`, or reuses the existing profile
- Writes SOUL.md into the profile directory
  - **Only if it is missing or still the Hermes installer's generic default.** A SOUL.md that differs from the template is kept, because Hermes may have self-corrected it during its Saturday rotation, or you may have edited it.
- Writes USER.md and MEMORY.md to `~/.hermes/memories/` (global, shared across profiles per the Hermes docs) if they are missing
  - MEMORY.md is refreshed if it still contains `version at install: unknown` or `Bootstrapped at TBD` (traces of an earlier, broken install)
- Sets `messaging.telegram/discord/slack.enabled` to `false` (Phase 1 has no Hermes gateway)

**`05-register-maintainer.sh`** registers the OpenClaw subagent:
- Writes `AGENTS.md` and `IDENTITY.md` from the rendered templates, plus `USER.md`, `MACHINE_LOG.md`, and `study-notes/README.md` if missing, under `~/hermes-maintainer/.openclaw-ws/`
- `openclaw agents add hermes-maintainer --non-interactive --workspace ~/hermes-maintainer/.openclaw-ws/` (skipped if already registered)
- Adds `hermes-maintainer` to `agents.defaults.subagents.allowAgents`, keeping any project subagents already there
- Restarts `openclaw-gateway` so the new subagent is reachable

**`06-cron-setup.sh`** is the most involved script. It:
1. Installs `~/.local/bin/heartbeat-patrol` (mode 755) from `lib/heartbeat-patrol.sh`
2. Writes `~/.config/heartbeat-patrol.env` (mode 600) when both a patrol bot token and a chat ID are known. The token defaults to the maintainer bot's token (then the main bot's), and the chat ID to `OPERATOR_TELEGRAM_USER_ID`. Without them, the patrol only logs to `_alerts.log`.
3. Seeds the five heartbeat files if missing, so the first patrol doesn't false-positive
4. Registers the four maintainer jobs with `openclaw cron add --session isolated --agent hermes-maintainer --no-deliver --light-context` (retrying without `--light-context` on builds that lack it). Each prompt has:
   - A **heartbeat-first prefix** (`STEP 1`) that runs `heartbeat-patrol --self <job>` before anything else
   - The task itself as `STEP 2`
   - A `SUMMARY_TAIL` asking the agent to list only positive actions (a workaround for the OpenClaw cron classifier flagging "did not" phrases as errors)
   Existing jobs with the same name are removed first, in a loop, so duplicates can't pile up.
5. Registers the Hermes-side job with `hermes -p openclaw-evolution cron create`
   - The prompt is the rendered `templates/hermes-daily-study-prompt.txt.tmpl`
   - Default schedule `0 10 * * *`, meant as 10:00 UTC (06:00 in New York during daylight time, after the maintainer jobs)
   - Idempotent: existing jobs by that name are removed in a loop before re-adding

**`07-smoke-test.sh`** runs 41 checks: tools, baseline files, `chattr +i` flags, hashes, the watcher unit, heartbeat files, the Hermes profile, the five jobs, and the subagent. The last three (a patrol dry run, `openclaw status`, `hermes doctor`) can only warn. Any FAIL makes it exit non-zero, which stops `all.sh`.

**`08-finalize.sh`** writes a `deploy_finalized` journal event and prints a summary with pointers to Phase 1.5 and Phase 2.

### 4.3 Phase 1.5: talk-helpers and maintainer Telegram

**`09-talk-helpers.sh`** writes wrapper scripts to `~/.local/share/openclaw-talk-helpers/` and symlinks them into `~/.local/bin/`:
- `talk-main`: `openclaw acp --session "agent:main:main"`
- `talk-maintainer`: `openclaw acp --session "agent:hermes-maintainer:main"`
- `talk-<agent>`: one for each other agent found in `openclaw agents list --json`
- `talk-hermes`: `hermes -p openclaw-evolution` (a different binary, not OpenClaw ACP)

Re-run it any time; the wrappers are regenerated. On OpenClaw 2026.5.20 and later the agent list comes back as a flat JSON array, which the script on `main` does not parse, so it falls back to `talk-main` and `talk-maintainer` only. Open pull request #1 fixes this.

**`10-tg-maintainer.sh`** connects a Telegram bot to `hermes-maintainer`:
- Reads `TG_BOT_HERMES_MAINTAINER_TOKEN` from `config/machine.env.secrets`. If it is empty, the phase is skipped.
- Sets `channels.telegram.accounts.hermes-maintainer.botToken` with `openclaw config set` (a no-op when the same token is already there, an update when it changed). On first setup it also sets that account's `proxy` to `HEARTBEAT_PATROL_PROXY`.
- Restarts `openclaw-gateway`
- Prints the manual pairing step: message the bot, receive a pairing code, reply with it to authorize

After pairing you can chat with `hermes-maintainer` on Telegram. The patrol alerts from the four maintainer jobs go out through `heartbeat-patrol`, which uses this bot's token by default (see [§3.5](#35-the-cross-patrol-heartbeat-phase-25)).

### 4.4 Phase 2: Hermes Telegram gateway

**`11-tg-hermes.sh`** enables Hermes's own gateway:
- Reads `TG_BOT_HERMES_AGENT_TOKEN` from `config/machine.env.secrets`. If it is empty, the phase is skipped.
- Sets `messaging.telegram.enabled true`, `messaging.telegram.bot_token`, and (when `OPERATOR_TELEGRAM_USER_ID` is set) `messaging.telegram.allowed_user_id` in the profile config
- `hermes -p openclaw-evolution gateway install --force` creates the profile-scoped user unit `hermes-gateway-openclaw-evolution.service`
- **`systemctl --user restart`** (not `start`), so a rotated token takes effect on a re-run

After this you can message Hermes directly. Per its SOUL, it does not push on its own; it replies to you. The one exception is the daily-study patrol alert in [§3.5](#35-the-cross-patrol-heartbeat-phase-25).

### 4.5 Phase 2.5: daily cron and cross-patrol heartbeat

This phase has no script of its own; `06-cron-setup.sh` in Phase 1 installs the patrol script and registers all five jobs.

**The Hermes daily-study prompt** (`templates/hermes-daily-study-prompt.txt.tmpl`) opens with a PATH CONVENTIONS block and then has five steps:

- **PATH CONVENTIONS**: Hermes's file tools resolve `~` inside its sandbox, so the prompt tells it to use absolute `/home/ubuntu/...` paths. This is why a host where the agents run as a different user needs a template edit (see [§10](#10-known-limitations)).
- **STEP 0**: find today's UTC weekday, date, and ISO week number with `date -u`. The template can't use `$(date)` itself, because envsubst doesn't expand `$()`.
- **STEP 1**: write the heartbeat first, with a file tool rather than the shell. The shell is chroot-jailed and would write into a sandbox copy of `home/.hermes/heartbeats/` instead of the real directory.
- **STEP 2**: read the four maintainer heartbeats and alert on any stale one (Telegram through its gateway when a chat ID is configured, otherwise a line in `~/.hermes/heartbeats/_alerts.log`).
- **STEP 3**: today's task, skipped if `MEMORY.md` already has a heading with today's date:
  - Monday: service signals (one service's MACHINE_LOG that hasn't been read in the past 7 days)
  - Tuesday: upstream OpenClaw commits and open issues from the past 7 days
  - Wednesday: the community ecosystem, with the source picked by ISO week modulo 4 (curator list, `openclaw-skill` topic, `openclaw-plugin` topic, official examples and forks)
  - Thursday: synthesize; draft `manifest.yaml` files in the inbox
  - Friday: pack readiness; write `summary.md` and `rollback-plan.md` for drafts that pass
  - Saturday: self-correct (prune MEMORY, promote recurring patterns to skills) and check Hermes releases
  - Sunday: rest
- **STEP 4**: a short summary reply.

The rotation gives broad coverage without heavy daily work. The prompt asks Hermes to keep STEP 3 within 30 minutes or 30 turns; that is an instruction, not an enforced limit, and the repo has no measured token-cost figures.

---

## 5. Pre-conditions

The host must already have:

1. **Linux with systemd user services**, and linger enabled (`sudo loginctl enable-linger $USER`) so they keep running after you log out
2. **OpenClaw** installed and running (`openclaw status` is happy; gateway running)
3. **An OpenClaw main agent workspace** at `~/.openclaw/workspace/`
4. **gh CLI** authenticated for your GitHub user (`gh auth status` is green)
5. **bash 4+**, `git`, `jq`, `curl`, `envsubst` (from `gettext`), `sha256sum`, `lsattr`/`chattr`
6. **sudo** for the installing user, for `chattr` (read the caveat in [§3.3](#33-the-hard-baseline-chattr-i--sha256--meta-hash))
7. **Optional**, for Phase 1.5 and Phase 2: a Telegram account and bot tokens from `@BotFather`

This template does NOT install OpenClaw; OpenClaw has its own installer.

---

## 6. What Lives Where After Install

| Path | Owner | Purpose |
|---|---|---|
| `~/.openclaw/workspace/baseline/` | operator (`chattr +i`) | hard policy: `baseline.policy.yaml`, `hermes-permissions.yaml`, `machine-mission.md`, `watcher.sh`, sha256 fingerprints |
| `~/.openclaw/workspace/heartbeats/` | maintainer jobs | one `*.last` file per maintainer job, plus `_alerts.log` |
| `~/.openclaw/workspace/upgrade-packs/inbox/` | Hermes (write) / main (read) | packs Hermes drafts, plus `_questions-for-operator.md` |
| `~/.openclaw/workspace/openclaw-local-diff.md` | operator | living document of local diffs against upstream |
| `~/.openclaw/workspace/evolution-journal.jsonl` | watcher, installer, maintainer, main | append-only event log |
| `~/.hermes/profiles/openclaw-evolution/` | Hermes | profile directory: SOUL.md, config |
| `~/.hermes/sessions/`, `~/.hermes/skills/` | Hermes | session history, generated skills |
| `~/.hermes/heartbeats/` | Hermes daily-study job | `hermes_daily_study.last`, plus `_alerts.log` when no chat ID is set |
| `~/.hermes/memories/` | Hermes | global MEMORY.md, USER.md (shared across profiles) |
| `~/hermes-maintainer/.openclaw-ws/` | maintainer subagent | bootstrap files, MACHINE_LOG.md, study-notes |
| `~/.local/bin/heartbeat-patrol` | scripts/06 | dead-man's-switch alerter |
| `~/.config/heartbeat-patrol.env` | scripts/06 (mode 600) | patrol bot token, chat ID, proxy |
| `~/.local/bin/talk-*` | scripts/09 | symlinks to wrappers in `~/.local/share/openclaw-talk-helpers/` |
| `~/.config/systemd/user/openclaw-watcher.service` | scripts/02 | watcher unit |
| `hermes-gateway-openclaw-evolution.service` | `hermes gateway install` (Phase 2) | Hermes's Telegram gateway (user unit) |

---

## 7. Daily Operations

What a normal day looks like:

- **04:30 local**: `hermes_daily_doctor`. The maintainer runs `hermes doctor`, appends a line to its `MACHINE_LOG.md`, and writes a `hermes_doctor_report` journal event (plus a study note when there are issues).
- **05:00 local**: `hermes_upstream_watch`. The maintainer checks `gh release list --repo NousResearch/hermes-agent --limit 5` against `known_good.hermes_version` in the baseline. For a newer release it writes a study note and a `hermes_release_review_pending` event for you.
- **05:00 local, Monday**: `hermes_weekly_review`. The maintainer runs `hermes -p openclaw-evolution insights --days 7`, writes a weekly review to `~/hermes-maintainer/.openclaw-ws/study-notes/`, and regenerates the three summaries Hermes reads.
- **05:30 local, 1st of the month**: `hermes_monthly_compress`. The maintainer runs `/compress` on Hermes's session memory and logs the sizes before and after.
- **10:00 UTC, daily**: `openclaw-daily-study`. Hermes wakes, picks the weekday's task, and writes findings to `MEMORY.md`, `skills/`, or `upgrade-packs/inbox/`.

Telegram stays quiet unless a job misses its window or you message a bot. Watcher findings (a lost `+i` flag, a hash mismatch, the gateway down) go to the evolution journal only, so look there when you check in.

To check in:
```bash
# Recent journal events
tail -50 ~/.openclaw/workspace/evolution-journal.jsonl | jq -c '{ts,event,actor}'

# Watcher findings, without the hourly heartbeats
jq -c 'select(.actor == "watcher" and .event != "watcher_heartbeat")' ~/.openclaw/workspace/evolution-journal.jsonl | tail

# Watcher + gateway alive
systemctl --user status openclaw-watcher openclaw-gateway

# Hermes profile health
hermes -p openclaw-evolution config show
hermes doctor

# Scheduled jobs
openclaw cron list
hermes -p openclaw-evolution cron list

# Heartbeat freshness
ls -la ~/.openclaw/workspace/heartbeats/ ~/.hermes/heartbeats/

# Patrol alerts (if any)
tail ~/.openclaw/workspace/heartbeats/_alerts.log ~/.hermes/heartbeats/_alerts.log
```

To talk to the agents:
```bash
talk-main           # OpenClaw main router
talk-maintainer     # hermes-maintainer subagent
talk-hermes         # Hermes Agent (openclaw-evolution profile)
```

---

## 8. Long-term Maintenance

- **Weekly**: glance at the journal (`tail ~/.openclaw/workspace/evolution-journal.jsonl | jq -c .`) and read the latest weekly review in `~/hermes-maintainer/.openclaw-ws/study-notes/`.
- **Monthly**: read the accumulated study notes; update `~/.openclaw/workspace/openclaw-local-diff.md` with any new local customizations you've made.
- **When Hermes finishes a pack**: the maintainer announces it with a `hermes_proposed` journal event. Main verifies it; low-risk and medium-risk packs can be applied within the change budget and maintenance window, and the rest wait for you. You can also tell main to apply or reject a pack through your usual channel.
- **When upstream Hermes releases**: the maintainer flags it with `hermes_release_review_pending`. You decide whether to run `hermes update` (agents may not; it is `forbidden_autonomous`).

To update the template itself: `git pull upstream main` (after adding the upstream remote as described in `docs/INSTALL.md`), then re-run `bash scripts/all.sh`. It is idempotent, but it re-renders and replaces the deployed baseline (see [§3.3](#33-the-hard-baseline-chattr-i--sha256--meta-hash)).

---

## 9. Lessons Baked In

Each entry below is a real bug, found either in the production deployment this template was extracted from or in the `/ultrareview` code review before the first release, along with the fix that is now structural in this template.

| # | Lesson | Where it lives now |
|---|---|---|
| 1 | **Heartbeat FIRST, not LAST** in cron prompts. When the patrol call was a suffix, agents wrote their summary as the final response BEFORE invoking the patrol, and the heartbeat never landed. | `scripts/06-cron-setup.sh` `heartbeat_prefix_for` |
| 2 | **Hermes's shell tool is chroot-jailed.** Calling `~/.local/bin/heartbeat-patrol` silently wrote the heartbeat into a sandbox-internal `home/.hermes/heartbeats/` instead of the real path. | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 1 uses a file tool, not the shell |
| 3 | **The OpenClaw cron classifier flags "did not" phrases** as errors. Confirmations like "I did not run hermes update" made successful runs show status=error. | `scripts/06-cron-setup.sh` `SUMMARY_TAIL` asks the agent to list only positive actions |
| 4 | **The watcher must `continue` on a broken journal**, not fall through. A non-writable journal would otherwise swallow the immutability, hash, and gateway findings silently. | `lib/watcher.sh` main loop: `if ! check_journal_writable; then sleep + continue` |
| 5 | **Heartbeat-patrol must verify the write landed.** Without `set -euo pipefail` AND a read-back check, a failed redirection (chattr +i, ENOSPC, read-only remount) would log to stderr but still print "OK". The dead-man's switch would lie. | `lib/heartbeat-patrol.sh` has `set -euo pipefail` + a `grep -qxF` check after the write |
| 6 | **`KNOWN_GOOD_HERMES_VERSION="unknown"`** would get baked into the `chattr +i` baseline if `01-render.sh` ran before `03-install-hermes.sh`. Once frozen, fixing it takes sudo. | `03-install-hermes.sh` re-runs `01-render` + `02-deploy-baseline --force` after install |
| 7 | **`SOUL.md` must survive re-runs.** An unconditional `cp` would destroy weeks of Hermes self-correction (the Saturday rotation prunes outdated entries). | `04-configure-hermes.sh` writes SOUL only if it is missing or still the Hermes installer's generic default |
| 8 | **`systemctl --user restart`, not `start`**, for credential rotation. `start` is a no-op when the unit is active, and the daemon keeps the old token. | `11-tg-hermes.sh` uses `restart` (as `10-tg-maintainer.sh` does for the gateway) |
| 9 | **`edit-baseline.sh` must call `load_config`** before referencing `$OPERATOR_HANDLE`. Without it, the post-edit journal call crashed under `set -u` after the files were already re-frozen. | `scripts/edit-baseline.sh` calls `load_config` after sourcing `common.sh` |
| 10 | **`$(date +%A)` doesn't expand in the daily-study template**, because envsubst only handles `${VAR}`. The template must have Hermes determine the day at runtime. | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 0 runs `date -u +%A` |
| 11 | **An empty Telegram chat ID** would interpolate to `chat  via your gateway` (a literal double space) and confuse Hermes. The prompt now checks explicitly that the chat ID is non-empty. | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 2 has the empty-string fallback |
| 12 | **The PII allowlist must work per match, not per line.** An earlier draft compared the whole grep line, so a line containing both a public IP and an RFC1918 IP was wrongly forgiven because the allowlisted RFC1918 prefix appeared somewhere in it. | `tests/check-no-pii.sh` `run_check` compares each match from `grep -oE` |
| 13 | **The PII allowlist must anchor IP-shaped prefixes.** Substring containment let public IPs through when their text contained an allowlisted RFC1918 prefix (a public IP whose second octet was `10` would match the `10.` entry). IPs now use `[[ $match == $allowed* ]]`. | `tests/check-no-pii.sh` `is_allowlisted` separates IP_PREFIX_ALLOWLIST from SUBSTRING_ALLOWLIST |
| 14 | **`tests/check-no-pii.sh` must not contain operator literals.** An earlier draft hardcoded private identifiers as regex literals; the script excluded itself, so the check passed while the literals sat in the committed file. | `tests/check-no-pii.sh` has only generic structural patterns; literals go in the gitignored `.pii-patterns.local` |
| 15 | **`heartbeat-patrol --self` (no value) must not crash** under `set -u`. Use `${2:-}` and a friendly usage path. | `lib/heartbeat-patrol.sh` argument parsing |
| 16 | **`while read` must salvage a file without a trailing newline.** `\|\| [ -n "$line" ]` keeps a final line the operator added without a closing `\n`. | `tests/check-no-pii.sh` patterns-file read loop |
| 17 | **`emit_journal_event` defaults to actor `installer`, not `main`.** Install scripts attributing actions to "main" mislead triage during a rescue. `edit-baseline.sh` passes `actor="operator"` explicitly. | `scripts/lib/common.sh` `emit_journal_event` |

These lessons come from running the setup in production for a while and putting the result through code review. They are now part of the structure, so the template won't quietly regress on them.

---

## 10. Known Limitations

- **The baseline is only as strong as the sudo setup.** The installer does not configure sudo. If the Linux user the agents run as has passwordless sudo, a shell-capable agent can run `sudo chattr -i` itself (see [§3.3](#33-the-hard-baseline-chattr-i--sha256--meta-hash)).
- **The watcher does not guard itself.** Its unit belongs to the agents' user, so it can be stopped without sudo. A clean stop writes one `watcher_stopped` event; after that, nothing notices the silence. The watcher writes an hourly `watcher_heartbeat`, but no job checks it yet. `disable_watcher` in `baseline.policy.yaml` is marked `todo_implement: cross_unit_liveness_check`. The cross-patrol heartbeat catches missed jobs, but if the watcher dies, its checks simply stop.
- **Most forbidden actions are policy, not code.** 8 of the 11 `forbidden_actions` are marked `todo_implement`. `remove_baseline` and `chattr_minus_i` are backed by `chattr +i` and the watcher; the rest rely on the main agent checking the policy before it applies a pack. The change budget is counted by the main agent too, not by code in this repo.
- **The daily-study prompt hardcodes `/home/ubuntu`.** Its PATH CONVENTIONS block spells out `/home/ubuntu/...` for Hermes's file tools. If the agents run as another user, edit `templates/hermes-daily-study-prompt.txt.tmpl` before installing.
- **OpenClaw 2026.5.20 and later.** Config paths were verified against OpenClaw v2026.5.x. On 2026.5.20+, `09-talk-helpers.sh` on `main` only creates `talk-main` and `talk-maintainer`; the fix is in open pull request #1.
- **Patrol alerts go through a proxy by default.** `heartbeat-patrol` sends Telegram messages through `HEARTBEAT_PATROL_PROXY` (default `http://127.0.0.1:8118`). Setting it to an empty string does not remove the proxy, because `load_config` fills the default back in. On a host with no proxy at that address, alerts only reach `_alerts.log`.
- **Budgets are instructions.** The 30-minute, 30-turn daily-study budget is a prompt instruction, not an enforced limit, and there are no measured token-cost figures.
- **The Hermes installer is fetched with `curl | bash`** from a configurable git ref. The default `main` tracks upstream; pin a tag with `HERMES_INSTALL_REF` in `machine.env` for reproducible installs. The install script's checksum is not verified.
- **Activity.** The last commit on `main` is from 2026-05-07 (v0.1.7), and pull request #1 has been open since 2026-05-23.

---

## 11. License

Apache-2.0. See [LICENSE](LICENSE).

## Related projects

- [OpenClaw](https://docs.openclaw.ai): the agent kernel. This template integrates through its public CLI (`openclaw cron`, `openclaw agents`, `openclaw config`) and **never modifies** OpenClaw's installed code, so `openclaw upgrade` is unaffected by anything it puts on disk.
- [Hermes Agent](https://github.com/NousResearch/hermes-agent): the long-running agent runtime. The template installs it with Hermes's upstream installer, then configures **one** profile (`openclaw-evolution`) through Hermes's public CLI. It **never modifies** Hermes itself; an operator-run `hermes update` goes through cleanly.
