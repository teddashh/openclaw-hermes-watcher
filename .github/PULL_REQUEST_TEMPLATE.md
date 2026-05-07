## What this PR does

<!-- One sentence summary. -->

## Why

<!-- The trigger: a bug you hit, an architectural improvement, a doc fix, etc.
     If you can name the failure mode this prevents in production, do that. -->

## Changes

<!-- Bullet list of files touched and what changed in each. -->

- `path/to/file.sh`: what changed
- `path/to/template.tmpl`: what changed

## Tests

- [ ] `for f in scripts/*.sh scripts/lib/*.sh lib/*.sh tests/*.sh; do bash -n "$f"; done` passes locally
- [ ] `bash tests/check-no-pii.sh` passes locally
- [ ] If a template was touched: rendered against `examples/solo-dev.env`, output looks sane
- [ ] If an install script was touched: tested end-to-end on a fresh host or VM (describe below)

## Manual test notes

<!-- If you tested on a real machine, describe:
     - host OS / OpenClaw version / Hermes version
     - did you do a fresh install or a re-run of scripts/all.sh on existing state?
     - any non-default machine.env values that mattered? -->

## Architectural impact

<!-- Does this change any of these load-bearing decisions? If yes, please link the relevant section in ARCHITECTURE.md or CONTRIBUTING.md and explain the tradeoff:
     - The four-role split (operator / main / maintainer / Hermes)
     - The file-only inter-role contract
     - The chattr +i hard baseline
     - The pure-bash watcher
     - The cross-patrol heartbeat
     - The five pack_kinds taxonomy
     - The two-file machine.env / machine.env.secrets split -->

## CHANGELOG entry

<!-- If this is a user-visible change (feature, bug fix, breaking change), add a CHANGELOG.md entry under [Unreleased] or the next version. -->

## Anything else

<!-- Related issues, context, gotchas. -->
