# Contributing

Thanks for thinking about it. This template is opinionated by design — most decisions trace back to a real production incident or a 4-AI architecture review. Before opening a PR, it's usually worth checking the [CHANGELOG](CHANGELOG.md) "Why" sections to see whether your change runs against an explicit prior decision.

## Quick path

1. Fork the repo, create a feature branch
2. Make your change
3. Run the same checks CI runs:
   ```bash
   for f in scripts/*.sh scripts/lib/*.sh lib/*.sh tests/*.sh; do bash -n "$f"; done
   bash tests/check-no-pii.sh
   ```
4. If you touched a template, render it against `examples/solo-dev.env` and confirm it parses:
   ```bash
   cp examples/solo-dev.env config/machine.env
   bash scripts/01-render.sh
   # check .render-cache/ for sane output
   ```
5. Open a PR. CI will re-run these.

## What changes are likely to land

- Bug fixes from real production runs, especially with a reproducer + the failure mode named (e.g., "v0.1.4 idempotency fixes" was a real-migration bug)
- Better error messages in install scripts
- Documentation clarifications, especially around the chroot-jail behavior of Hermes filesystem tools (recurring source of confusion)
- New `pack_kind` taxonomy entries with structural justification
- CI improvements (faster, clearer failure surface)
- Translations of the README beyond the current English / 繁體中文 pair

## What changes are less likely to land

- Adding a new agent role to the four-role split — that's a load-bearing architectural decision, has friction-with-debate-distillation
- Changing the file-only inter-role contract to RPC — same
- Introducing LLM-as-judge into Layer 0 — explicitly rejected; see ARCHITECTURE.md §3.4 / §3.5
- "Cleaner" rewrites that drop production-tested edge cases (most of the script complexity exists for a reason — see CHANGELOG)
- Adding telemetry/observability that ships to a third-party endpoint by default

If you're proposing one of these, please open an issue first to discuss the tradeoff before writing code.

## Testing your change against a real machine

This template was extracted from a working host. The cleanest test is to install it onto a fresh machine (or a VM) end-to-end:

1. New host with OpenClaw already installed
2. Fork → clone → `bash scripts/all.sh`
3. Run `bash scripts/07-smoke-test.sh` and verify 39+/0/0
4. Trigger one cron manually (`openclaw cron run <id>`) and inspect the result

If you don't have a spare host, render-only tests catch ~70% of breakage; the remaining ~30% are "this script's behavior on a real Hermes / OpenClaw install" edge cases.

## Code style

- Bash scripts: `set -euo pipefail` unless there's a documented reason not to (e.g., `lib/heartbeat-patrol.sh` uses just `set -u` historically; v0.1.4 added `set -euo pipefail` after the silent-OK bug)
- Markdown: GitHub-flavored. Tables for structured info, fenced code blocks, no emojis unless the operator's `OPERATOR_LANGUAGES` calls for it
- YAML: 2-space indent, strings quoted only when needed, comments on their own lines
- Templates: `${VAR}` for substitution. Add new vars to `scripts/lib/render-template.sh:ALLOWED_VARS` AND default them in `scripts/lib/common.sh:load_config`
- File names: lower-kebab-case for scripts, lower-snake_case for env keys, PascalCase for Markdown if it follows convention (README, SECURITY)

## Reporting bugs

Open a GitHub issue. If the bug exposes a real exploit path, follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree your contributions are licensed under [Apache 2.0](LICENSE), the same as the rest of the repo.
