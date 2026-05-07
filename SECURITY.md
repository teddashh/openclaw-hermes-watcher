# Security policy

This template installs an LLM agent on a host with operator-level access to a running OpenClaw deployment. It manages secrets, baseline policies, systemd units, and bot tokens. Security issues here can compromise an operator's whole machine. Please report them responsibly.

## Reporting a vulnerability

**Do not file vulnerabilities as public GitHub issues.** Public issues are indexed immediately; if a real exploit is described, attackers see it before operators do.

Instead:

1. Email the maintainer at the address listed in the repo's GitHub profile, or
2. Use [GitHub's "Report a vulnerability" private flow](https://github.com/teddashh/openclaw-hermes-watcher/security/advisories/new) (Security → Advisories → Report a vulnerability).

Include:
- A description of the issue and the path it affects
- A minimal reproduction or affected code reference
- The OpenClaw + Hermes versions you're running (`openclaw --version` / `hermes --version`)
- Any mitigations you've already applied

You should expect:
- An acknowledgement within 7 days
- A first triage assessment within 14 days
- A fix or coordinated disclosure plan within 30 days for confirmed issues

## What's in scope

- Bypasses of the `chattr +i` baseline (any way an LLM agent gets to modify policy files without `sudo`)
- Token exfiltration paths (any code path that could leak `~/.config/machine.env.secrets` or `~/.openclaw/openclaw.json` tokens)
- Privilege escalation via the install scripts (e.g., a path where an unprivileged user invokes a script that runs sudo with attacker-controlled arguments)
- Cross-patrol heartbeat alert spoofing (false-positive or suppressed alerts)
- Watcher silenceability (any way to stop or mislead `watcher.sh` without filesystem-level access)
- Hermes profile / SOUL.md tampering through the inbox path

## What's out of scope

- Vulnerabilities in OpenClaw itself — report those to [openclaw/openclaw](https://github.com/openclaw/openclaw)
- Vulnerabilities in Hermes Agent itself — report those to [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- Issues that require root on the host (root already bypasses the baseline; this template's threat model is "agent is unprivileged user")
- Theoretical attacks against `chattr +i` (it's a kernel filesystem flag; that's the threat model boundary)

## Bot tokens

If you accidentally committed a bot token to a public repo (private repos are also at risk via mirroring/forks), the immediate action is:

1. Tell @BotFather `/revoke` for that bot — invalidates the token
2. Generate a new token via `/token`
3. Update your `config/machine.env.secrets` with the new value
4. Re-run `bash scripts/06-cron-setup.sh` (regenerates `~/.config/heartbeat-patrol.env`) and `bash scripts/10-tg-maintainer.sh` / `bash scripts/11-tg-hermes.sh` (for the corresponding bot)
5. (If committed to git history) `git filter-repo` or BFG to strip the token from history, then force-push, then alert any clones / forks

The template's two-file split (`machine.env` committable, `machine.env.secrets` gitignored) is precisely to make this scenario rare. If you find a leaked token in the public template's git history, that's a security issue worth reporting via the private flow above.
