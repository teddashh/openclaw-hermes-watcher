# openclaw-hermes-watcher

**[English](README.md)** | [繁體中文](README.zh-TW.md)

> ## Manage the machine with OpenClaw's discipline.
> ## Manage its evolution with Hermes's diligence.
> ### Two agents, helping each other.

A drop-in **layer** on top of an existing [OpenClaw](https://docs.openclaw.ai) host. Adds a focused [Hermes Agent](https://github.com/NousResearch/hermes-agent) profile that studies OpenClaw upstream, a guardian subagent that maintains the Hermes install, a `chattr +i` policy baseline that no agent can rewrite, and a deterministic cross-patrol heartbeat that surfaces failures the agents themselves cannot — **without modifying OpenClaw's or Hermes's installed code.** Integration is via their public CLI and conventional file locations only, so `openclaw upgrade` and `hermes update` flow through unaffected.

Apache-2.0. v0.1.0. 39 files. Three rounds of cloud code review.

---

## Table of Contents

1. [TL;DR — Quick Start](#1-tldr--quick-start)
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
   - 4.2 [Phase 1 — install](#42-phase-1--install-hermes--maintainer--baseline--watcher)
   - 4.3 [Phase 1.5 — talk-helpers + maintainer Telegram](#43-phase-15--talk-helpers--maintainer-telegram)
   - 4.4 [Phase 2 — Hermes Telegram gateway](#44-phase-2--hermes-telegram-gateway)
   - 4.5 [Phase 2.5 — daily cron + heartbeat](#45-phase-25--daily-cron--cross-patrol-heartbeat)
5. [Pre-conditions](#5-pre-conditions)
6. [What Lives Where](#6-what-lives-where-after-install)
7. [Daily Operations](#7-daily-operations)
8. [Long-term Maintenance](#8-long-term-maintenance)
9. [Lessons Baked In](#9-lessons-baked-in)
10. [Known Limitations](#10-known-limitations)
11. [License](#11-license)

---

## 1. TL;DR — Quick Start

You already have OpenClaw running. You want a long-running Hermes agent + guardian + dead-man's-switch on top. Five commands:

```bash
git clone https://github.com/<you>/openclaw-hermes-watcher
cd openclaw-hermes-watcher
cp config/machine.env.example config/machine.env
$EDITOR config/machine.env             # fill in operator + machine + bot tokens
bash scripts/all.sh                     # idempotent end-to-end install
```

Verify: `bash scripts/07-smoke-test.sh`. From this point Hermes wakes daily, rotates focus, writes findings to files. Maintainer cron jobs cross-monitor each other plus Hermes; a Telegram alert fires only if a job actually misses its window. See [§7 Daily Operations](#7-daily-operations) for what you'll experience day to day.

If you want to understand why the architecture is shaped this way before committing, read on. Sections 2–4 are the educational deep dive.

---

## 2. The Problem This Solves

You run an OpenClaw deployment. The router is up, the workspace is bootstrapped, your project subagents are registered, the Telegram bots are paired. Life is good. Now you want a long-running agent that watches OpenClaw upstream — reads commits, reads issues, builds a model of what your local diffs are, drafts upgrade-packs when there's a release worth applying — without you babysitting it daily, and without giving it enough rope to talk itself into things you didn't authorize.

The naive approaches fail in specific, predictable ways:

### 2.1 "Just run a daily cron that diffs upstream and pings me on Slack."

- One month in, you've started ignoring the pings. **Approval fatigue.**
- Three months in, you've drifted six minor versions behind. The first ping you actually read is "23 commits, 4 breaking" — too much to evaluate at once.
- The cron knows nothing about your local diffs. Its breaking-change list is a superset of "things that actually break here". You stop trusting the noise.

### 2.2 "Give Claude Code (or another general agent) the task ad-hoc."

- Each session starts cold. No accumulated model of "why did we customize file X three months ago?"
- Each session has a different opinion on what's worth applying. **Taste drift** between sessions.
- You're paying for context-rebuild every time. The cost compounds.

### 2.3 "Let the agent self-update without supervision."

- Worked great until the day it didn't. A bad upgrade with no rollback path is unrecoverable in a single shell.
- The agent has no incentive to preserve your local diffs; the agent's incentive is "land the upgrade".
- The first thing a misaligned agent learns to do is silence the alert that would have caught it.

### 2.4 What this template does instead

- **A long-running agent (Hermes)** develops over weeks and months as a focused expert on OpenClaw evolution. Its accumulated model lives in `~/.hermes/memories/MEMORY.md` and `~/.hermes/skills/`. It does not start cold.
- **A guardian subagent (`hermes-maintainer`)** runs scheduled checks on Hermes itself — `hermes doctor`, weekly insights summary, monthly compress, upstream watch. It cannot apply anything; only the operator decides.
- **A hard baseline (`chattr +i` policy YAML files)** encodes what the agent MUST NOT do regardless of how convincing a future proposal is. No LLM can rewrite it because rewriting requires sudo, which agents don't have.
- **A watcher (50-line bash, systemd user unit)** verifies the baseline 60 times per hour. It's not an LLM — it's pure rule-based code. It cannot be argued with.
- **A cross-patrol heartbeat** ensures Telegram only alerts you when something is actually broken (a cron didn't run). Healthy operation is silent.

The result is a system you can leave alone. You walk in once a month, glance at `~/.openclaw/workspace/evolution-journal.jsonl`, see what Hermes has been studying, decide whether any drafted pack is worth applying. Otherwise, silence.

---

## 3. Architecture: Why Each Layer Exists

**Integration boundary first.** This template is a layer that integrates with OpenClaw and Hermes via their public CLI (`openclaw cron / agents / config`, `hermes profile / config / cron / gateway`) and conventional file locations (`~/.openclaw/workspace/`, `~/.hermes/profiles/<name>/`). It **never modifies** their installed code:

| Path | Touched by this template? |
|---|---|
| `/usr/lib/node_modules/openclaw/` (OpenClaw installed code) | **No** — listed in `baseline.policy.yaml:immutable_paths` |
| `~/.hermes/hermes-agent/` (Hermes installed code) | **No** — managed only via `hermes update`, operator-approved |
| `~/.openclaw/openclaw.json` (OpenClaw main config) | **No direct write** — only via `openclaw config set` |
| `~/.openclaw/workspace/baseline/` (this template's policy files) | Yes — chattr +i after deploy, operator-only edits |
| `~/.hermes/profiles/openclaw-evolution/` (one Hermes profile) | Yes — Hermes's documented profile mechanism |
| `~/hermes-maintainer/.openclaw-ws/` (subagent workspace) | Yes — OpenClaw's documented subagent mechanism |

The full file inventory is in [§6 What Lives Where](#6-what-lives-where-after-install). Practical consequence: `openclaw upgrade` and `hermes update` (operator-approved) flow through without touching anything this template puts on disk.

Each layer below earns its space — what it does, why it's needed, and what failure mode it addresses. The architecture takes deliberate positions on six known-hard problems any long-running-agent-on-production-host design must answer (see [§3.6](#36-how-we-address-the-six-known-hard-problems)).

### 3.1 The four roles

Architecture has four agent roles plus one human:

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
   ┌─────────────────────────────────────────────────────┐
   │ OpenClaw workspace subagents                         │
   │ ─────────────────────────────────────────────────── │
   │ <your project subagents — out of scope for this repo> │
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

**Rule of thumb: if you can't tell from a directory listing what each role is doing, the deployment has gone wrong.** Every role's footprint is in plain markdown / JSONL / YAML — readable by humans, by future Claude Code rescues, and by other agents in the system. No proprietary state, no opaque SQLite blobs you have to interpret.

#### 3.1.1 Operator (Principal)

The human. Ultimate authority. The architecture exists to *not* require you to babysit; it preserves your ability to walk in cold and understand state, but does not require it.

You communicate with the agents via:
- CLI (`talk-main`, `talk-hermes`, etc. — Phase 1.5+)
- Telegram bots (per-agent, opt-in via Phase 1.5/Phase 2)
- SSH + direct file edits (always available)

You hold authority that no agent has:
- `sudo chattr -i` — only you can unfreeze the baseline (via `scripts/edit-baseline.sh`)
- `hermes update` — only you decide when to upgrade Hermes (the maintainer flags releases, you act)
- Pack apply — main applies after verification, but only after the pack is in the inbox and you've decided

#### 3.1.2 OpenClaw main agent

**Job:** Route requests. Manage host-level concerns (Caddy, Docker, systemd, ports, SSL, backups). Apply Hermes-produced upgrade packs after verification. Write the evolution journal. Govern subagents.

**Cannot:** Modify files matching `immutable_paths` in `baseline.policy.yaml`. Modify the watcher unit or its policy (`chattr +i` enforced). Modify Hermes's source install (`~/.hermes/hermes-agent/`) except by running the documented `hermes update` flow with operator approval.

**Footprint:** `~/.openclaw/workspace/MACHINE_LOG.md`, `evolution-journal.jsonl`, `DEVIATIONS.md`.

#### 3.1.3 hermes-maintainer subagent

A workspace subagent whose only job is to keep the local Hermes Agent install healthy, current, and aligned with what it's supposed to be doing. **Hermes's medic and archivist, not its boss.**

**Allowed:**
- Run `hermes doctor`, `hermes status`, `hermes -p openclaw-evolution insights --days N`
- Read `~/.hermes/sessions/`, memories, skills (read-only)
- Read upstream Hermes repo to track releases
- Write study notes to `~/hermes-maintainer/.openclaw-ws/study-notes/`
- Notify main agent via journal when Hermes needs attention

**Cannot:**
- Edit Hermes's SOUL.md / USER.md / MEMORY.md (those are Hermes's own state)
- Modify `~/.hermes/.env` (operator only — API keys)
- Apply Hermes-produced upgrade packs (only main may, after verification)
- Modify the baseline or watcher
- Run `hermes update` autonomously — that's in `forbidden_autonomous`; surface as journal event for operator

**Why this exists separate from main:** The maintainer's daily/weekly cadence is dedicated to Hermes-related signals. It doesn't compete with main's host-management workload. Its bootstrap files (`AGENTS.md`, `IDENTITY.md`) anchor it to the narrow role even when the operator hasn't visited in weeks.

#### 3.1.4 Hermes Agent (`openclaw-evolution` profile)

**Job:** Long-term study of OpenClaw upstream. Read commits, issues, release notes. Maintain a deepening model of what was customized locally and why. Produce upgrade-packs when an OpenClaw release would be valuable to apply. Use its self-improvement loop to get better at this *one* job over time.

**Allowed:**
- Read `~/.openclaw/` (read-only)
- Read upstream OpenClaw repo via `gh` CLI or REST fallback
- Write to its own `~/.hermes/` profile dir (sessions, memories, skills, SOUL)
- Produce upgrade-pack artifacts in `~/.openclaw/workspace/upgrade-packs/inbox/`
- Talk to operator via CLI or Telegram (Phase 2, optional)

**Cannot:**
- Write to `~/.openclaw/` directly except via the upgrade-pack inbox
- Apply its own upgrade-packs
- Modify `~/.hermes/.env`
- Modify the watcher or baseline policy
- Spawn shell processes outside its sandbox (Hermes's shell tool is chroot-jailed — see [§9 Lessons Baked In](#9-lessons-baked-in))

### 3.2 The file contract

> **Roles do NOT chat with each other. They communicate by writing structured files that the others read.**

This is the single most important architectural rule in the system. No agent-to-agent prompt-passing, no live RPC, no negotiation. Each role writes to disk in a format the others (and Claude Code, in a rescue scenario) can read.

| From → To | Channel | Format |
|---|---|---|
| Hermes → main | Upgrade-pack drop dir | `manifest.yaml` + diffs |
| main → Hermes | Evolution journal entries | append-only JSONL |
| hermes-maintainer → main | Study notes + journal entries | markdown + JSONL |
| Any subagent → main | `MACHINE_LOG.md` updates | markdown |
| Operator → any | CLI / Telegram / SSH | conversational |

**Why files, not RPC:**

1. **Auditability.** A pack proposal is a file you can `cat`. A journal event is a JSONL line you can `jq`. There's no transient state, no "what did the agents say to each other yesterday" question. If it happened, it's on disk.
2. **Rescue.** When something goes wrong and you SSH in cold, plain markdown / JSONL / YAML are the most rescue-friendly formats that exist. No daemons to inspect, no network endpoints to query, just files.
3. **Async by default.** The agents don't need to be online at the same time. Hermes drafts a pack on Monday at 06:00 UTC; main reads it Wednesday at 04:30 EDT during its scheduled run. Each role moves at its own pace.
4. **No agent-to-agent persuasion.** When Hermes wants main to apply a pack, it writes a `hermes_proposed` event with the pack ID. It does not write prose to convince main. Main reads the manifest.yaml and decides.
5. **Symmetry with rescue agents.** When you (or Claude Code) walk in to investigate "what's going on with this host," you read the same files the agents do. There's no hidden inter-agent state you'd have to recover.

### 3.3 The hard baseline (chattr +i + sha256 + meta-hash)

`~/.openclaw/workspace/baseline/` contains four policy files plus two integrity hashes:

```
baseline/
├── baseline.policy.yaml         # forbidden_actions, immutable_paths, allow_write_for_main, change_budget, require_approval
├── hermes-permissions.yaml      # what Hermes may/may-not do
├── machine-mission.md           # what this host is for
├── watcher.sh                   # periodic sentinel
├── .expected-hashes             # sha256 of the four files above
└── .expected-hashes.sha256      # meta-hash, sha256 of .expected-hashes itself
```

All six are `chattr +i` (immutable) after deploy.

**Why chattr +i** (rather than just file permissions):
- Linux file permissions can be changed by the file's owner. The `ubuntu` user (which agents run as) owns the baseline files; without chattr, any agent could `chmod` them and rewrite.
- `chattr +i` makes a file truly immutable at the kernel level. Writing requires `chattr -i` first, which requires `sudo`. Agents don't have sudo. Operator does.
- This is the single most load-bearing security property in the system. Without it, every other layer is decorative — an LLM that decides the policy is "outdated" can simply rewrite it.

**Why a `.expected-hashes` file** (rather than just trusting chattr):
- chattr +i prevents writes when set, but a sufficiently-clever attacker could (in principle) tamper with the file's data outside the filesystem layer (raw block device write, etc.). Defense in depth says: verify hashes too.
- More practically: the operator might forget to re-freeze after editing via `scripts/edit-baseline.sh`. The watcher catches this and emits a `baseline_immutability_lost` event.

**Why a meta-hash** (`.expected-hashes.sha256`):
- This is the chicken-and-egg fix. If `.expected-hashes` itself were tamperable, an attacker could rewrite both a baseline file AND the `.expected-hashes` line for that file in lockstep, defeating the hash check.
- The meta-hash is the sha256 of `.expected-hashes` itself, stored in a separate file. The watcher verifies the meta-hash before trusting `.expected-hashes`. To break this, the attacker would need to rewrite three files in lockstep — and any one of them being chattr +i breaks the chain.

**Editing the baseline** is operator-only via `scripts/edit-baseline.sh`. That script:
1. `sudo chattr -i` on the target + the two hash files
2. Opens the file in `$EDITOR`
3. Regenerates `.expected-hashes` and `.expected-hashes.sha256`
4. `sudo chattr +i` on everything
5. Emits an `operator_edited_baseline` journal event with `actor=operator`

If you forget step 4 (re-freeze), the watcher will notice within 60 seconds and emit `baseline_immutability_lost`. There's no way to silently leave the baseline mutable.

### 3.4 The watcher (deterministic bash, not an LLM)

A pure-bash systemd user unit at `~/.config/systemd/user/openclaw-watcher.service`, firing every 60 seconds. It runs `~/.openclaw/workspace/baseline/watcher.sh` (which itself is chattr +i).

Every tick, the watcher:
- Verifies all baseline files still have `chattr +i`
- Verifies all sha256 hashes match `.expected-hashes`
- Verifies the meta-hash of `.expected-hashes` matches `.expected-hashes.sha256`
- Verifies `openclaw-gateway` process is running
- Once per hour, emits a `watcher_heartbeat` event so you know the watcher itself is alive

Anomalies emit JSONL events to `~/.openclaw/workspace/evolution-journal.jsonl`. The watcher does not act on anomalies — it just records them. The main agent (or operator on next visit) reads and decides.

**Why pure bash, not an LLM:**
- An LLM watcher can be argued with. "This file change is fine because X." A pure-rule watcher cannot. It computes a hash, compares it to a fingerprint, emits a JSONL event if mismatch. There's nothing to negotiate with.
- The principle: **a watcher that needs to think can be talked into permitting things; a watcher that's just a write-protected file is uncompromisable.**

**Why systemd user unit, not system unit:**
- User units don't require root. The watcher runs as the same `ubuntu` user the gateway runs as.
- User units are easier to install (`~/.config/systemd/user/`) and don't require modifying `/etc/systemd/system/`.
- Tradeoff: user units cannot drop CAP_SYS_ADMIN-requiring capabilities (`LockPersonality`, `MemoryDenyWriteExecute`, etc.). Defense in depth here is at the policy + filesystem layers (`chattr +i`, sudo restrictions), not at kernel-namespace level. Documented in the unit file.

**Why the watcher's checks are minimal:**
- Every additional check is one more thing to maintain. The four checks above are the load-bearing ones.
- Extending the watcher is a heavy decision because the watcher itself is `chattr +i`. Edit via `scripts/edit-baseline.sh`.

### 3.5 The cross-patrol heartbeat (Phase 2.5)

A deterministic dead-man's-switch that replaces "alarm fires when broken" with **"alarm fires when nobody dismissed it via fresh heartbeat."**

Five scheduled jobs run regularly:

| Job | Default schedule | Owner |
|---|---|---|
| `hermes_daily_doctor` | 04:30 local daily | hermes-maintainer (OpenClaw cron) |
| `hermes_upstream_watch` | 05:00 local daily | hermes-maintainer (OpenClaw cron) |
| `hermes_weekly_review` | Mon 05:00 local | hermes-maintainer (OpenClaw cron) |
| `hermes_monthly_compress` | 1st 05:30 local | hermes-maintainer (OpenClaw cron) |
| `openclaw-daily-study` | 10:00 UTC daily | Hermes Agent (Hermes cron) |

Each, **on success**, writes a heartbeat file with its current timestamp + interval + grace. Then it patrols the four other heartbeats; if any is stale beyond `interval + grace`, it sends a Telegram alert via the configured bot.

**Why heartbeat-FIRST in the cron prompt** (not last):

We learned this the hard way. When the patrol call was a SUFFIX on the agent prompt, the agent would write its summary ("Done. ... I did not run hermes update.") as its FINAL response *before* invoking the patrol script. The OpenClaw cron framework treats the first textual summary as run completion, so the suffix never fires — heartbeat never landed. Putting `STEP 1: heartbeat-patrol` at the start of the prompt guarantees the heartbeat is written and peers patrolled before the agent ever produces a final summary, even if downstream tasks run out of turns or the classifier short-circuits. See `scripts/06-cron-setup.sh:heartbeat_prefix_for`.

**Why a separate alerter script** (`heartbeat-patrol`):

The patrol logic must be deterministic. If the patrol itself were an LLM call, it would have the same alignment failure modes as the agents being patrolled. So `heartbeat-patrol` is 150 lines of bash — it writes a heartbeat, reads peers, computes (now − last_timestamp), compares to (interval + grace), and curls Telegram on staleness. No LLM in the alert path.

**Why "default broken alert dismissed by fresh heartbeat" rather than "alarm on failure":**

If the alarm fires on failure, the alarm path itself becomes a single point of failure. Crash the alerter and you get silence. With the heartbeat-as-dismissal pattern, the *absence* of action triggers the alarm, so the alarm path doesn't need to be running to alert you — the next still-alive peer's patrol will fire on stale-peer-detection.

**Why each agent uses its own bot for alerts** (rather than one shared bot):

Different bots = different "voices" in your Telegram client. When `@*_watchbot` pings you it's the maintainer that detected staleness. When `@*_hermesbot` replies it's Hermes itself. If something is wrong with one agent, the alert from the other agent's bot still gets through.

**The Hermes-side cron is special** — it uses Hermes's own cron scheduler, not OpenClaw cron, because:
- OpenClaw cron with `--session isolated --agent X` runs as an OpenClaw subagent, not as Hermes.
- Hermes's daily-study task needs to write to Hermes's own state (sessions, memories, skills) — only Hermes itself has clean write access there.
- Hermes's shell tool is chroot-jailed (more on this in §9), so the daily-study cron prompt instructs Hermes to use its native `filesystem_write` tool with **absolute paths** rather than the patrol script, which lives outside the jail.

### 3.6 How we address the six known-hard problems

Long-running cognitive agents on production hosts have to take positions on six known-hard problems. This template doesn't claim to fully solve them; it takes explicit stances on each.

| Problem | Stance | Where in the code |
|---|---|---|
| **Cold start** — first-week behavior is qualitatively different | Maintainer's daily-doctor cron runs from day 1, so observability isn't conditional on the agent already being trustworthy | `scripts/06-cron-setup.sh` registers cron immediately after install |
| **Recursive upgrade** — agent updating itself | `hermes update` is in `forbidden_autonomous`; operator-only | `templates/baseline.policy.yaml.tmpl:forbidden_actions[id=...]` |
| **Taste drift** — agent's preferences diverge from operator's | SOUL.md preserved across re-runs; maintainer's weekly review surfaces drift signals | `scripts/04-configure-hermes.sh` only writes SOUL.md if missing |
| **Approval fatigue** — operator stops reading proposals carefully | Drafts go to inbox dir; no autonomous Telegram push; operator pulls when curious | `templates/SOUL.md.tmpl` "Output goes to FILES, not Telegram pushes" |
| **Token cost** — agent's own thinking is expensive | Daily rotation by day-of-week limits per-day burn; idempotency check skips already-done work | `templates/hermes-daily-study-prompt.txt.tmpl` "skip if already done today" |
| **Fleet sharing** — coordinating across machines | Explicitly out of scope; one host, one config | No fleet logic anywhere |

---

## 4. Implementation Walk-through

Each architectural decision has a corresponding piece of code. This section walks through the install in order and points at the files that implement each layer.

### 4.1 Repository layout

```
openclaw-hermes-watcher/
├── README.md                          ← you are here (English)
├── README.zh-TW.md                    ← 繁體中文
├── ARCHITECTURE.md                    ← deep architecture (concise; this README has the long form)
├── CHANGELOG.md
├── LICENSE                            ← Apache-2.0
├── .gitignore                         ← machine.env + heartbeat-patrol.env + .pii-patterns.local
│
├── config/
│   └── machine.env.example            ← per-machine config template (operator copies + edits)
│
├── lib/                               ← generic shell, ships as-is, no rendering
│   ├── heartbeat-patrol.sh            ← deterministic dead-man's-switch alerter (150 lines)
│   └── watcher.sh                     ← baseline sentinel (200 lines, runs every 60s)
│
├── templates/                         ← .tmpl files rendered via envsubst-with-allowlist
│   ├── machine-mission.md.tmpl        ← what this host is for (chattr +i after deploy)
│   ├── baseline.policy.yaml.tmpl      ← hard floor: forbidden_actions, immutable_paths, ...
│   ├── hermes-permissions.yaml.tmpl   ← Hermes's allowed/denied scope
│   ├── SOUL.md.tmpl                   ← Hermes's identity (preserved across re-runs after first install)
│   ├── USER.md.tmpl                   ← Hermes's view of the operator
│   ├── MEMORY.md.tmpl                 ← Hermes's accumulated knowledge bootstrap
│   ├── hermes-daily-study-prompt.txt.tmpl  ← the daily cron prompt (heartbeat-FIRST)
│   ├── hermes-maintainer-AGENTS.md.tmpl    ← maintainer subagent's role spec
│   ├── hermes-maintainer-IDENTITY.md.tmpl  ← maintainer's short identity blurb
│   └── openclaw-watcher.service.tmpl       ← systemd user unit
│
├── scripts/                           ← install scripts, run in numbered order
│   ├── 00-prereqs.sh                  ← check OpenClaw, gh, jq, systemd, machine.env
│   ├── 01-render.sh                   ← templates/ → .render-cache/ via envsubst
│   ├── 02-deploy-baseline.sh          ← chattr +i baseline, install + start watcher
│   ├── 03-install-hermes.sh           ← curl | bash upstream installer (--skip-setup)
│   ├── 04-configure-hermes.sh         ← create profile, write SOUL/USER/MEMORY
│   ├── 05-register-maintainer.sh      ← register hermes-maintainer OpenClaw subagent
│   ├── 06-cron-setup.sh               ← install heartbeat-patrol + 5 cron jobs
│   ├── 07-smoke-test.sh               ← end-to-end verification
│   ├── 08-finalize.sh                 ← summary + next steps
│   ├── 09-talk-helpers.sh             ← Phase 1.5: talk-* ACP shortcut wrappers
│   ├── 10-tg-maintainer.sh            ← Phase 1.5: maintainer's Telegram bot
│   ├── 11-tg-hermes.sh                ← Phase 2: Hermes's own Telegram gateway
│   ├── all.sh                         ← orchestrator (runs 00-11 idempotently)
│   ├── edit-baseline.sh               ← operator-only: safely edit chattr +i files
│   └── lib/
│       ├── common.sh                  ← shared helpers (load_config, emit_journal_event)
│       └── render-template.sh         ← envsubst with explicit allowlist
│
├── docs/
│   ├── INSTALL.md                     ← step-by-step
│   ├── PHASE-2-TELEGRAM.md            ← @BotFather flow for Phase 2
│   └── ROLLBACK.md                    ← uninstall sequence
│
└── tests/
    ├── check-no-pii.sh                ← CI guard: no operator literals in committed files
    ├── .pii-patterns.local.example    ← operator-specific pattern template (gitignored copy)
    └── (.pii-patterns.local — gitignored)
```

### 4.2 Phase 1 — install Hermes + maintainer + baseline + watcher

The heart of the install. Order matters and is enforced by file naming (`00-` through `08-`).

**`00-prereqs.sh`** verifies the host is ready:
- bash 4+, jq, curl, envsubst, sha256sum, lsattr/chattr, systemd --user, gh CLI authenticated
- OpenClaw installed and `openclaw status` happy
- `~/.openclaw/workspace/` exists (main agent bootstrap done)
- `loginctl enable-linger` set (so user systemd survives logout)
- `config/machine.env` present and minimal fields set

Fails fast with actionable error messages. No state changes.

**`01-render.sh`** renders the templates:
- Sources `config/machine.env` via `load_config` from `scripts/lib/common.sh`
- Auto-detects `KNOWN_GOOD_*_VERSION` from installed binaries (or `unknown` if not yet installed — fixed up in step 03)
- Calls `render_template` (in `scripts/lib/render-template.sh`) which wraps `envsubst` with an explicit allowlist of variable names
- Outputs to `.render-cache/` (gitignored)

**Why envsubst with allowlist** (rather than bare envsubst): bare envsubst substitutes any `$VAR` in the input. Templates legitimately contain `$()` shell snippets and `$VAR` references that should stay literal. The allowlist lets us name exactly which vars get substituted, leaving the rest as literal text.

**`02-deploy-baseline.sh`** stages the chattr +i layer:
1. Reads `.render-cache/`
2. Detects existing baseline + unfreezes if content differs (`sudo chattr -R -i`)
3. Copies rendered files to `~/.openclaw/workspace/baseline/`
4. Regenerates `.expected-hashes` (sha256sum of all `*.yaml`/`*.md`/`watcher.sh`) and `.expected-hashes.sha256` (meta-hash)
5. Installs systemd user unit at `~/.config/systemd/user/openclaw-watcher.service` (rendered with `__HOME__` substituted)
6. **`sudo chattr +i`** on baseline files + both hash files
7. `systemctl --user enable + start openclaw-watcher`
8. Bootstraps `~/.openclaw/workspace/upgrade-packs/inbox/`, `heartbeats/`, stubs `openclaw-local-diff.md`

If the watcher fails to start, deployment halts — leaving an unenforced baseline is worse than no baseline.

**`03-install-hermes.sh`** runs the upstream Hermes installer:
- Checks if hermes is already installed (idempotent skip)
- Runs `curl -fsSL .../install.sh | bash -s -- --skip-setup` (skip-setup so the wizard doesn't auto-migrate OpenClaw state into Hermes)
- After install, **re-runs `01-render.sh` and `02-deploy-baseline.sh --force`** to fix the "unknown" hermes_version that was baked in before hermes existed on PATH (this is one of the lessons from the ultrareview rounds)

**`04-configure-hermes.sh`** creates the Hermes profile:
- `hermes profile create openclaw-evolution`
- Writes SOUL.md to the profile dir (per-profile)
  - **Only if missing OR identical to template** — preserves Hermes's self-corrected SOUL across re-runs (the Thursday rotation lets Hermes prune outdated entries)
- Writes USER.md and MEMORY.md to `~/.hermes/memories/` (global, shared across profiles per Hermes docs)
  - MEMORY.md refreshes if it contains `version at install: unknown` (botched earlier install)
- Sets profile config defaults (gateway off in Phase 1)

**`05-register-maintainer.sh`** registers the OpenClaw subagent:
- Pre-bakes `~/hermes-maintainer/.openclaw-ws/{AGENTS,IDENTITY,USER,MACHINE_LOG}.md` from rendered templates
- `openclaw agents add hermes-maintainer --workspace ~/hermes-maintainer/.openclaw-ws/`
- Updates `agents.defaults.subagents.allowAgents` to include `hermes-maintainer` (preserving any project subagents already there)
- Restarts `openclaw-gateway` so the new subagent is reachable

**`06-cron-setup.sh`** is the most involved script. It does:
1. Installs `~/.local/bin/heartbeat-patrol` (chmod 755) from `lib/heartbeat-patrol.sh`
2. Writes `~/.config/heartbeat-patrol.env` (chmod 600) from `machine.env` values
3. Seeds heartbeat files with current timestamp (so first patrol doesn't false-positive)
4. Registers the four maintainer cron jobs via `openclaw cron add`, each with:
   - **Heartbeat-FIRST prefix** (`STEP 1`) calling `heartbeat-patrol --self <jobname>` BEFORE the actual task
   - The original task as `STEP 2`
   - A `SUMMARY_TAIL` instructing the agent to list only positive actions in summary (workaround for the OpenClaw cron classifier's "did not" denial-token false-positive)
5. Registers the Hermes-side daily-study cron via `hermes -p openclaw-evolution cron create`
   - Renders `templates/hermes-daily-study-prompt.txt.tmpl` to a real prompt
   - Schedules at `0 10 * * *` UTC (06:00 EDT, after maintainer crons finish)
   - Idempotent: removes existing duplicates in a loop before re-adding

**`07-smoke-test.sh`** verifies 39+ invariants and counts pass/fail. Exits non-zero on any FAIL.

**`08-finalize.sh`** prints a summary + "what's next" pointer to Phase 1.5/Phase 2.

### 4.3 Phase 1.5 — talk-helpers + maintainer Telegram

**`09-talk-helpers.sh`** generates wrapper scripts in `~/.local/bin/`:
- `talk-main` — `openclaw acp --session "agent:main:main"`
- `talk-maintainer` — `openclaw acp --session "agent:hermes-maintainer:main"`
- `talk-<your-project-subagent>` — auto-discovered from `openclaw agents list --json`
- `talk-hermes` — `hermes -p openclaw-evolution` (different binary; not via OpenClaw ACP)

These are idempotent symlinks. Re-run anytime; they refresh.

**`10-tg-maintainer.sh`** registers a Telegram bot for `hermes-maintainer`:
- Reads `TG_BOT_HERMES_MAINTAINER_TOKEN` from `machine.env`. If empty, skips entirely.
- Adds the bot via `openclaw gateway telegram add` (or `openclaw config set` fallback)
- Restarts `openclaw-gateway`
- Prints next-step manual instruction: message your bot to receive a pairing code, reply to authorize

After pairing, you can chat with `hermes-maintainer` via Telegram. The maintainer also uses this bot for cross-patrol alerts (Phase 2.5) — see [§3.5](#35-the-cross-patrol-heartbeat-phase-25).

### 4.4 Phase 2 — Hermes Telegram gateway

**`11-tg-hermes.sh`** enables Hermes's own gateway:
- Reads `TG_BOT_HERMES_AGENT_TOKEN` from `machine.env`. If empty, skips.
- Sets `messaging.telegram.enabled true` + bot_token + allowed_user_id in the Hermes profile config
- `hermes -p openclaw-evolution gateway install --force` creates a profile-scoped systemd unit `hermes-gateway-openclaw-evolution.service`
- **`systemctl --user restart`** (not `start`) — so a token rotation actually takes effect on re-run

After this, you can message Hermes directly. Per its SOUL contract, it does not autonomously push — only replies to your messages.

### 4.5 Phase 2.5 — daily cron + cross-patrol heartbeat

This phase has no dedicated script — it's enabled as part of Phase 1's `06-cron-setup.sh`. The daily Hermes cron registration and the heartbeat-patrol install both happen there.

**The Hermes daily-study prompt** (in `templates/hermes-daily-study-prompt.txt.tmpl`) has four steps:

1. **STEP 0** — establish today's UTC day-of-week via `date -u +%A` (template can't use `$(date)` because envsubst doesn't expand `$()`, and Hermes's prompt is text-not-shell)
2. **STEP 1** — write heartbeat FIRST. Use `filesystem_write` (NOT shell — Hermes's shell is chroot-jailed and would write into the sandbox-internal `home/.hermes/heartbeats/` instead of the real `/home/<user>/.hermes/heartbeats/`)
3. **STEP 2** — patrol the four maintainer heartbeats; alert via Telegram if any stale
4. **STEP 3** — today's rotation task (Mon: commits, Tue: subsystem deep-read, Wed: issues themes, Thu: self-correct, Fri: pack-readiness, Sat: Hermes self, Sun: rest). Skip if `MEMORY.md` already has today's date heading.
5. **STEP 4** — brief reply summarizing what was done.

The rotation gives broad coverage without daily heavy work. Average: ~10-30k tokens per day. Token cost discussed in [§3.6](#36-how-we-address-the-six-known-hard-problems).

---

## 5. Pre-conditions

The host must already have:

1. **OpenClaw** installed and running (`openclaw status` returns happy; gateway running)
2. **OpenClaw main agent workspace** at `~/.openclaw/workspace/`
3. **gh CLI** authenticated for your GitHub user (`gh auth status` is green)
4. **bash 4+**, `jq`, `curl`, `envsubst` (from `gettext`), `sha256sum`, `lsattr`/`chattr`, `systemd --user` with linger enabled
5. **Optional** for Phase 1.5/Phase 2: Telegram account + bot tokens via `@BotFather`

This template does NOT install OpenClaw itself — that's the user's job, and OpenClaw has its own installer.

---

## 6. What Lives Where After Install

| Path | Owner | Purpose |
|---|---|---|
| `~/.openclaw/workspace/baseline/` | operator (chattr +i) | hard policy: `baseline.policy.yaml`, `hermes-permissions.yaml`, `machine-mission.md`, `watcher.sh`, sha256 fingerprints |
| `~/.openclaw/workspace/heartbeats/` | maintainer crons | one `*.last` file per maintainer cron job |
| `~/.openclaw/workspace/upgrade-packs/inbox/` | Hermes (write) / main (read) | draft packs Hermes proposes |
| `~/.openclaw/workspace/openclaw-local-diff.md` | operator | living document of local diffs vs upstream |
| `~/.openclaw/workspace/evolution-journal.jsonl` | OpenClaw main | append-only event log |
| `~/.hermes/profiles/openclaw-evolution/` | Hermes | profile state: SOUL.md, sessions, skills, gateway |
| `~/.hermes/heartbeats/` | Hermes daily-study cron | `hermes_daily_study.last` |
| `~/.hermes/memories/` | Hermes | global MEMORY.md, USER.md (shared across profiles) |
| `~/hermes-maintainer/.openclaw-ws/` | maintainer subagent | bootstrap files + study-notes |
| `~/.local/bin/heartbeat-patrol` | scripts/06 | dead-man's-switch alerter |
| `~/.config/heartbeat-patrol.env` | operator (chmod 600) | bot token + chat ID |
| `~/.config/systemd/user/openclaw-watcher.service` | scripts/02 | systemd unit |

---

## 7. Daily Operations

What you'll experience day to day:

- **04:30 local** — `hermes_daily_doctor` cron fires. Maintainer runs `hermes doctor`, writes a line to its `MACHINE_LOG.md`, no alert if happy. Heartbeat written.
- **05:00 local** — `hermes_upstream_watch` fires. Maintainer scans `NousResearch/hermes-agent` for new tags. If a release is found, writes a study-note + journal event `hermes_release_review_pending` for you to review.
- **05:00 local Mon** — `hermes_weekly_review` fires. Maintainer runs `hermes -p openclaw-evolution insights --days 7` and writes a weekly summary to `~/hermes-maintainer/.openclaw-ws/study-notes/`.
- **05:30 local 1st of month** — `hermes_monthly_compress` fires. Maintainer runs `/compress` to compact Hermes's session memory.
- **10:00 UTC daily** — `openclaw-daily-study` fires. Hermes itself wakes, rotates focus by day-of-week, writes findings to `MEMORY.md` / `skills/` / `upgrade-packs/inbox/`.

You never get a Telegram unless something is actually broken. Healthy operation is silent.

To check in:
```bash
# Recent journal events
tail -50 ~/.openclaw/workspace/evolution-journal.jsonl | jq -c '{ts,event,actor}'

# Watcher + gateway alive
systemctl --user status openclaw-watcher openclaw-gateway

# Hermes profile health
hermes -p openclaw-evolution config show
hermes doctor

# Cron job status
openclaw cron list
hermes -p openclaw-evolution cron list

# Heartbeat freshness
ls -la ~/.openclaw/workspace/heartbeats/ ~/.hermes/heartbeats/

# Patrol alerts (if any)
tail ~/.openclaw/workspace/heartbeats/_alerts.log
```

To converse with the agents:
```bash
talk-main           # OpenClaw main router
talk-maintainer     # hermes-maintainer subagent
talk-hermes         # Hermes Agent (openclaw-evolution profile)
```

---

## 8. Long-term Maintenance

- **Weekly**: glance at the journal `tail ~/.openclaw/workspace/evolution-journal.jsonl | jq -c .` and check `~/hermes-maintainer/.openclaw-ws/study-notes/` for the latest weekly review.
- **Monthly**: read accumulated study notes; consider whether `~/.openclaw/workspace/openclaw-local-diff.md` needs updating with new local customizations you've made.
- **When upstream OpenClaw releases**: Hermes drafts a pack to `upgrade-packs/inbox/<tag>/`. The maintainer flags it via journal `hermes_proposed`. You review, then trigger main to apply (or reject) via your normal channel.
- **When upstream Hermes releases**: maintainer flags via `hermes_release_review_pending`. You decide whether to run `hermes update` (it's `forbidden_autonomous`).

To update this template itself: `git pull upstream main` (after setting up the upstream remote per `docs/INSTALL.md`), then re-run `bash scripts/all.sh`. Idempotent.

---

## 9. Lessons Baked In

Each entry below is a real bug from the production deployment OR from one of three rounds of `/ultrareview` cloud code review, and the fix that's now structural in this template.

| # | Lesson | Where it lives now |
|---|---|---|
| 1 | **Heartbeat-FIRST not LAST** in cron prompts. When the patrol call was a SUFFIX, agents wrote their summary as the final response BEFORE invoking patrol — heartbeat never landed. | `scripts/06-cron-setup.sh:heartbeat_prefix_for` |
| 2 | **Hermes shell tool is chroot-jailed.** Calling `~/.local/bin/heartbeat-patrol` silently wrote heartbeat into a sandbox-internal `home/.hermes/heartbeats/` instead of the real path. | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 1 uses `filesystem_write` not shell |
| 3 | **OpenClaw cron classifier flags "did not" denial tokens** as errors. Agent confirmation phrases like "I did not run hermes update" caused successful runs to show status=error. | `scripts/06-cron-setup.sh:SUMMARY_TAIL` instructs agent to list only positive actions |
| 4 | **Watcher must `continue` on broken journal**, not fall through. A non-writable journal would otherwise fail the immutability/hash/gateway checks silently into the dead file. | `lib/watcher.sh` main loop has `if ! check_journal_writable; then sleep + continue` |
| 5 | **Heartbeat-patrol must verify the write landed.** Without `set -euo pipefail` AND a read-back check, a failed redirection (chattr +i, ENOSPC, RO remount) would log to stderr but still print "OK". Dead-man's-switch would lie. | `lib/heartbeat-patrol.sh` has `set -euo pipefail` + `grep -qxF` post-write verification |
| 6 | **`KNOWN_GOOD_HERMES_VERSION="unknown"`** would get baked into the chattr +i baseline if `01-render.sh` ran before `03-install-hermes.sh`. Once frozen, sudo to fix. | `03-install-hermes.sh` re-runs `01-render` + `02-deploy-baseline --force` after install |
| 7 | **`SOUL.md` must be preserved across re-runs.** Unconditional `cp` would destroy weeks of Hermes self-correction (Thursday rotation prunes outdated entries). | `04-configure-hermes.sh` only writes SOUL if missing or identical to template |
| 8 | **`systemctl --user restart` not `start`** for credential rotation. `start` is no-op when active; daemon keeps old token. | `11-tg-hermes.sh` uses `restart` (matches `10-tg-maintainer.sh`) |
| 9 | **`edit-baseline.sh` must `load_config`** before referencing `$OPERATOR_HANDLE` — without it, the post-edit journal call crashed under `set -u` after files were already re-frozen. | `scripts/edit-baseline.sh` calls `load_config` after sourcing `common.sh` |
| 10 | **Hermes daily-study `$(date +%A)` doesn't expand** because envsubst only handles `${VAR}`. Template must instruct Hermes to determine day at runtime. | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 0 calls `date -u +%A` |
| 11 | **Empty Telegram chat ID** would interpolate to `chat  via your gateway` (literal double space), confusing Hermes. Prompt now explicitly conditions on the chat ID being non-empty. | `templates/hermes-daily-study-prompt.txt.tmpl:STEP 2` has the empty-string fallback |
| 12 | **PII allowlist must be per-match, not per-line.** Earlier draft compared whole grep-line; a line containing both a public IP and an RFC1918 IP was wrongly forgiven because the line contained the allowlisted RFC1918 prefix somewhere. | `tests/check-no-pii.sh:run_check` uses per-match comparison via `grep -oE` |
| 13 | **PII allowlist must anchor IP-shaped prefixes.** Substring containment let public IPs through if their decimal-string-form contained an allowlisted RFC1918 prefix as a substring (a public IP whose second octet was `10` would match the `10.` allowlist entry). Now uses `[[ $match == $allowed* ]]` for IPs. | `tests/check-no-pii.sh:is_allowlisted` splits IP_PREFIX_ALLOWLIST vs SUBSTRING_ALLOWLIST |
| 14 | **`tests/check-no-pii.sh` must not contain operator literals.** Earlier draft hardcoded private identifiers as regex literals; the script self-excluded so the check passed green while the literals sat in the committed file. | `tests/check-no-pii.sh` has only generic structural patterns; literals go in gitignored `.pii-patterns.local` |
| 15 | **`heartbeat-patrol --self` (no value) must not crash** under `set -u`. Use `${2:-}` and friendly usage path. | `lib/heartbeat-patrol.sh` arg parsing |
| 16 | **`while read` must salvage trailing-newline-less files.** `\|\| [ -n "$line" ]` salvages a final line the operator added without a closing `\n`. | `tests/check-no-pii.sh` patterns-file read loop |
| 17 | **`emit_journal_event` default actor = `installer`, not `main`.** Install scripts attributing actions to "main" misleads rescue-time triage. `edit-baseline.sh` passes `actor="operator"` explicitly. | `scripts/lib/common.sh:emit_journal_event` |

These lessons are the value of running things in production for a while AND putting the result through code review. They're now structural — the template won't regress.

---

## 10. Known Limitations

- **The watcher cannot detect its own disablement.** A stopped process emits no events. Documented in `baseline.policy.yaml` `forbidden_actions[id=disable_watcher]` as `todo_implement: cross_unit_liveness_check`. Mitigation: cross-patrol heartbeat catches missed runs; if both watcher and patrol die, the system silently drifts.
- **Hermes installer fetched via `curl | bash`** from a configurable git ref. Default `main` tracks upstream; pin to a tag in `machine.env` (`HERMES_INSTALL_REF`) for reproducible installs. We do not yet verify a sha256 of the install.sh contents.
- **No CI workflow yet.** PRs must be syntax-checked manually (`bash -n scripts/*.sh`) and run through `tests/check-no-pii.sh`.
- **Examples directory is empty.** `examples/solo-dev.env`, `examples/shared-server.env` etc. should ship with v0.2.

---

## 11. License

Apache-2.0. See [LICENSE](LICENSE).

## Related projects

- [OpenClaw](https://docs.openclaw.ai) — the agent kernel. This template integrates with OpenClaw via its public CLI (`openclaw cron`, `openclaw agents`, `openclaw config`); it **never modifies** OpenClaw's installed code. `openclaw upgrade` is unaffected by anything we put on disk.
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) — the long-running agent runtime. We install it via Hermes's upstream installer, then configure **one** profile (`openclaw-evolution`) using Hermes's public CLI. We **never modify** Hermes itself; `hermes update` (operator-approved) flows through cleanly.
