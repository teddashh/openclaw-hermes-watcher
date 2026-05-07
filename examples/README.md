# Example machine.env files

Reference configurations to copy and adapt. None of these contain real bot tokens — those go in `config/machine.env.secrets` (gitignored, per-machine).

| File | Use case |
|---|---|
| [`solo-dev.env`](solo-dev.env) | Single developer, one machine, one or two side projects, no Phase 2 (Hermes Telegram disabled) |
| [`shared-server.env`](shared-server.env) | Multi-service production host (e.g., 3 services with their own subagents), full Phase 1.5 + Phase 2 enabled, like the host this template was extracted from |

To use:

```bash
cp examples/solo-dev.env config/machine.env
$EDITOR config/machine.env   # adjust to your operator + machine
cp config/machine.env.secrets.example config/machine.env.secrets
$EDITOR config/machine.env.secrets   # paste real bot tokens
bash scripts/all.sh
```

The examples are sized differently:

- `solo-dev.env` is minimal. Most fields use defaults. No project subagents, no Phase 2. Closest to "I just want to evolve OpenClaw on my dev box, nothing fancy."
- `shared-server.env` has all the surface area filled in. Multi-service descriptions, all 5 maintainer-side bots configured, Phase 2 Hermes-side bot enabled, services declared in `MACHINE_SERVICES_MD`, project subagent MACHINE_LOG paths declared via `HERMES_READ_EXTRA_PATHS_MD`. Closest to "I run real services for real users; this OpenClaw + Hermes pair tracks them."

Both files have inline comments explaining each field. Walk through them top to bottom.

## What if my situation is between these two?

That's fine. Pick whichever is closer and trim / extend. The fields not used (e.g., empty `TG_BOT_*_NAME`) cause the corresponding install phase to be skipped — see `scripts/10-tg-maintainer.sh` and `scripts/11-tg-hermes.sh` for the gating.
