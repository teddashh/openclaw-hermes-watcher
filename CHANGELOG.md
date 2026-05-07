# Changelog

All notable changes to this template will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.7] — 2026-05-07

Public-facing polish for the now-public repo. No code or template changes; documentation only.

### Added

- **`README.md` / `README.zh-TW.md`** — three shield badges at top: CI status, Apache-2.0 license, latest release.
- **`SECURITY.md`** — vulnerability reporting flow (private), explicit scope (what's in / out), token-leak emergency response steps.
- **`CONTRIBUTING.md`** — quick path, what's likely / unlikely to land (with pointers to ARCHITECTURE.md), pre-PR test checklist, code-style notes.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — diagnostic info reviewers need.
- **`.github/ISSUE_TEMPLATE/feature_request.md`** — guides proposers toward addressing architectural-impact tradeoffs upfront.
- **`.github/PULL_REQUEST_TEMPLATE.md`** — pre-flight checklist mirroring CI checks plus an architectural-impact prompt.
- GitHub repository topics: `openclaw`, `hermes-agent`, `agent`, `ai-agent`, `agentic-os`, `bash`, `chattr`, `dead-mans-switch`, `systemd`, `template`.
- Refined GitHub repository description.

## [0.1.6] — 2026-05-07

Public-readiness pieces.

### Added

- **`examples/solo-dev.env`** — minimal one-machine config, no Phase 2.
- **`examples/shared-server.env`** — multi-service multi-bot, full Phase 1.5+2.
- **`examples/README.md`** — picking guide.
- **`.github/workflows/test.yml`** — CI that runs `bash -n` on all `.sh`, `tests/check-no-pii.sh`, and a template-render smoke (renders `solo-dev.env` against templates and confirms no untouched `${VAR}` placeholders remain).

### Why

These two land together because they're the "ready for public" pieces: examples are the reference for friends to copy, CI is the guardrail for PRs to that public repo.

## [0.1.5] — 2026-05-07

Hermes self-reported during a Telegram-triggered production verification test that its `read_file` / `write_file` / `patch` tools resolve `~` against the sandboxed `home/` directory, not the host's real `$HOME`. This caused it to silently waste turns retrying with absolute paths when reading baseline files.

### Changed

- **`templates/hermes-daily-study-prompt.txt.tmpl`** — added a "PATH CONVENTIONS" section at top of the prompt explaining that filesystem tools (not just shell) resolve `~` to the sandbox-internal `home/`. Rule: always use absolute `/home/ubuntu/...` paths for self-formulated tool calls. Template-rendered `${HOME}/...` paths are safe (they get expanded at render time).

### Why

This was the same chroot-jail behavior already documented for the shell tool (see project memory `feedback_minimal_agent_files.md` and `project_hermes_phase1.md`), but the existing prompt only warned about shell — not about the native filesystem tools. Production verification on 2026-05-07 surfaced that Hermes hits this on every read attempt with `~`-prefixed paths, fallback-recovers via absolute path, but loses a turn each time.

## [0.1.4] — 2026-05-06

Two idempotency fixes discovered during the first real migration of an existing OpenClaw host onto this template.

### Changed

- **`scripts/04-configure-hermes.sh`** — SOUL.md detection now recognizes Hermes installer's generic default ("You are Hermes Agent, an intelligent AI assistant...") and replaces it with the rendered service-chain version. Without this, an `rm SOUL.md` followed by `scripts/all.sh` would have Hermes regenerate its generic default before 04 ran, causing 04 to fall into the "preserve current" branch and leave the operator with the wrong SOUL.
- **`scripts/10-tg-maintainer.sh`** — uses the real OpenClaw config schema (`channels.telegram.accounts.<agent>.botToken`) verified against v2026.5.x, not the guessed `gateway.telegram.bots.<agent>.token` path that earlier versions tried. Also: idempotent — if the bot is already configured with the same token, no-op; if different, update. Re-running `scripts/all.sh` on an already-deployed host no longer errors at this step.

### Why

Both bugs hide until you actually re-deploy onto an existing host (which is exactly the migration path documented in `docs/INSTALL.md` for fork updates). v0.1.4 is the first version that's been migration-tested.

## [0.1.3] — 2026-05-06

Fills the gap v0.1.1 left between SOUL.md (which says "Hermes's primary food is each service's MACHINE_LOG") and `hermes-permissions.yaml` (which only listed the maintainer's MACHINE_LOG, not project subagents'). Operators couldn't actually grant Hermes the permission its SOUL claimed.

### Changed

- **`templates/hermes-permissions.yaml.tmpl`** — `hermes_may.read:` now includes a `${HERMES_READ_EXTRA_PATHS_MD}` substitution slot for operator-supplied additional read paths (typically project subagent MACHINE_LOG files).
- **`config/machine.env.example`** — new `HERMES_READ_EXTRA_PATHS_MD` field with example showing the YAML-list format.
- **`scripts/lib/render-template.sh`** — added `HERMES_READ_EXTRA_PATHS_MD` to ALLOWED_VARS allowlist so envsubst substitutes it.
- **`scripts/lib/common.sh`** — defaults `HERMES_READ_EXTRA_PATHS_MD=""` and exports it.

### Why

Without this, render-time hermes-permissions had a TODO comment ("Add other subagent workspace logs here") that operators were expected to manually edit post-render. That broke the "render once, deploy idempotently" flow. Now operators declare the paths in `machine.env`, render handles the rest.

## [0.1.2] — 2026-05-06

Splits secrets from non-secret config so private forks can commit `machine.env` without bot tokens entering git history.

### Changed

- **`config/machine.env.example`** — bot TOKEN fields removed (now in `machine.env.secrets.example`). Bot NAMES (usernames) stay here. `HEARTBEAT_PATROL_BOT_TOKEN` removed (lives in secrets); `HEARTBEAT_PATROL_CHAT_ID` stays (PII but not credential).
- **`config/machine.env.secrets.example`** — new file. Holds `TG_BOT_*_TOKEN` fields and `HEARTBEAT_PATROL_BOT_TOKEN`. Gitignored everywhere.
- **`.gitignore`** — adds `config/machine.env.secrets`. Comment block clarifies the split.
- **`scripts/lib/common.sh`** — `load_config()` sources `machine.env.secrets` after `machine.env` (if present). Tokens missing = phase skipped, same behavior as before.
- **`docs/INSTALL.md`** — Step 3 now describes the two-file split and which fields go where.

### Why

Even private GitHub repos are not vaults; tokens belong on the machine, not in git. The split also makes per-machine forks cleaner: clone the private fork on a new machine, the structure is there, the secrets file gets created locally.

## [0.1.1] — 2026-05-06

Reframes Hermes from "OpenClaw upstream integration engineer" to **service evolution scout**, in response to a 4-AI critique of v0.1.0 that correctly identified the diet (input source) was wrong.

### Changed

- **`templates/SOUL.md.tmpl`** — Hermes's identity rewritten around the service chain (User → Services → OpenClaw → Hermes). Hermes's `ONE job` is now "actively evolve OpenClaw on this host so it serves the operator's services better over time", with success measured against service health (stability / latency / error rate / recovery time / ease of upgrade), not upstream conformance. Four food sources defined in priority order: service signals (primary), upstream OpenClaw (supporting), community ecosystem (discovery), accumulated MEMORY (compound).
- **`templates/hermes-daily-study-prompt.txt.tmpl`** — daily rotation reorganized to distribute the four food sources:
  - Mon: read one service's MACHINE_LOG (rotating)
  - Tue: upstream OpenClaw, cross-referenced against Mon's pain points
  - Wed: community ecosystem (4-week source rotation through awesome lists, `topic:openclaw-skill`, `topic:openclaw-plugin`, NousResearch examples)
  - Thu: synthesize draft evolution-packs
  - Fri: pack readiness review
  - Sat: self-correct + Hermes self-awareness
  - Sun: rest
  Wed includes an explicit candidate-evaluation checklist (activity / license / safety pre-screen / version compat / **service relevance**) so community discoveries get filtered before reaching Thu's synthesis pool.
- **`templates/machine-mission.md.tmpl`** — adds "The service chain" section explaining what each layer of the stack ultimately serves. Operator preferences renumbered with service-first / layer-only as the top two principles.
- **`templates/baseline.policy.yaml.tmpl`** — adds `pack_kinds` taxonomy formalizing five evolution-pack types: `install_skill` and `install_plugin` (structurally non-modifying — extension points only — `auto_apply_in_window: true`), `apply_upstream_patch` (medium risk, auto-apply with verification), `synthesize_custom` and `config_change` (operator review required). Each kind has a `default_tier` and a `rollback_pattern`.
- **`README.md` / `README.zh-TW.md`** — §3 architecture intro updated to mention community ecosystem as the natural extension of the layer-only commitment (skills/plugins are extension points, not modifications). §3.1.4 Hermes Agent role rewritten to reflect service-evolution-scout framing.

### Deferred to v0.2

- **Cognitive OOM kill in watcher** (acute pathology guard): Token-burn velocity, tool-call thrashing, context-growth thresholds. The watcher.sh runs as systemd checking baseline files; adding runtime telemetry needs a separate mechanism (likely a sibling daemon polling Hermes's session DB or hooking into its API call path). Bigger architectural decision than v0.1.1 should bundle.
- **Trace artifact pipeline schema**: formalize the structure of service MACHINE_LOG into queryable trace records.
- **Replay / benchmark harness**: empirical fitness function for evolution-pack proposals.
- **Layer 1.5 chronic drift monitoring**: frozen canary set + periodic SOUL behavior-diff review.

## [0.1.0] — 2026-05-06

Initial extraction from a working production deployment.

### Added

- Phase 1: Hermes Agent install, `openclaw-evolution` profile, `hermes-maintainer` OpenClaw subagent, chattr +i baseline, watcher systemd unit, 4 maintainer cron jobs, smoke test.
- Phase 1.5: opt-in Telegram bot for `hermes-maintainer`, `talk-*` ACP shortcut wrappers.
- Phase 2: opt-in Telegram bot for the Hermes Agent itself, profile-scoped systemd unit.
- Phase 2.5: daily Hermes-side cron (`openclaw-daily-study`) with rotating focus, cross-patrol heartbeat dead-man-switch (`heartbeat-patrol` script + alert config).
- Apache-2.0 license, README, ARCHITECTURE doc, `machine.env.example` schema with versioning.
- `tests/check-no-pii.sh` to guard against private identifiers leaking into the public template.
- `scripts/all.sh` orchestrator for end-to-end install.
- `scripts/edit-baseline.sh` helper for safely editing chattr +i files.

### Pre-release fixes (from `/ultrareview` pass)

- `tests/check-no-pii.sh` rewritten to keep PII patterns OUT of the committed
  script. Operator-specific literals now live in gitignored
  `tests/.pii-patterns.local` (per `tests/.pii-patterns.local.example`).
  The committed script ships only generic structural regexes
  (email-shaped, IPv4-shaped, Telegram-bot-token-shaped) with an
  allowlist for loopback / RFC1918 / `example.com` style placeholders.
- `scripts/edit-baseline.sh` now calls `load_config` before referencing
  `$OPERATOR_HANDLE`. Previously crashed under `set -u` after re-freezing
  files, silently dropping the `operator_edited_baseline` audit entry.
- `lib/watcher.sh` now `continue`s on a non-writable journal instead of
  falling through; without this, all subsequent checks would silently no-op
  via their `|| true` masks against a dead journal.
- `templates/hermes-daily-study-prompt.txt.tmpl` adds a STEP 0 telling
  Hermes to determine the day-of-week via `date -u +%A` at runtime;
  previously the template embedded a literal `$(date +%A)` which
  `envsubst` doesn't expand and Hermes can't substitute on its own.
- `scripts/03-install-hermes.sh` now pins to `${HERMES_INSTALL_REF}`
  (default `main`, override in `machine.env` for reproducible installs)
  instead of always fetching `main`.
- `lib/heartbeat-patrol.sh` argument parsing handles bare `--self`
  (no value) gracefully via friendly usage instead of crashing under
  `set -u` on unbound `$2`.
- `docs/ROLLBACK.md` no longer implies a `machine.env` knob exists for
  Phase 2.5 partial-rollback that doesn't.

### Known limitations

- Cron classifier false-positive: when a maintainer cron's prompt instructs the agent NOT to do something, the agent's confirmation summary may contain "did not" tokens, which OpenClaw's post-run classifier flags as denial errors. Worked around by rephrasing prompts to "out-of-scope" language plus a `SUMMARY_TAIL` instruction to list only positive actions. See `scripts/06-cron-setup.sh`.
- Hermes shell tool is chroot-jailed: scripts that resolve `~` resolve it inside Hermes's profile sandbox, not real $HOME. The Hermes-side daily-study cron prompt instructs Hermes to use its native `filesystem_write` tool with absolute paths.
- The watcher cannot detect its own disablement (a stopped process emits no events). Documented in `baseline.policy.yaml` `forbidden_actions[id=disable_watcher]` as `todo_implement: cross_unit_liveness_check`.
- Hermes installer is fetched via `curl | bash` from a configurable git ref. Default `main` tracks upstream; pin to a specific tag in `machine.env` (`HERMES_INSTALL_REF`) for reproducible installs, but we do not yet verify a sha256 of the install.sh contents.
