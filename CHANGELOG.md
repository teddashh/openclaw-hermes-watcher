# Changelog

All notable changes to this template will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
