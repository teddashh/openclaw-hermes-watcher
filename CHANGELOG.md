# Changelog

All notable changes to this template will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
