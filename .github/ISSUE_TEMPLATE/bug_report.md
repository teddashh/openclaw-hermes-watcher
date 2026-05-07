---
name: Bug report
about: Something didn't work the way the docs / script comments suggest
title: ''
labels: bug
assignees: ''
---

## What happened

<!-- One sentence: what did you expect, what did you get? -->

## Reproducer

<!-- The minimal sequence of commands. If a long install, name which scripts/* you ran and where it failed. -->

```bash
# example
cp examples/solo-dev.env config/machine.env
$EDITOR config/machine.env  # filled in: ...
bash scripts/all.sh
# fails at: ...
```

## Environment

- OpenClaw version: <!-- output of `openclaw --version` -->
- Hermes version:   <!-- output of `hermes --version` -->
- Host OS:          <!-- output of `uname -srm` -->
- This repo at commit: <!-- output of `git rev-parse HEAD` -->

## Logs / output

<!-- Paste the last ~30 lines of relevant output. Redact tokens / chat IDs / your PII. -->

```
<paste here>
```

## What you tried

<!-- What did you do to narrow the issue down? -->

## Anything else

<!-- Other info: did this happen on a fresh install or after `git pull upstream main`? Was it a re-run of `scripts/all.sh` or first install? -->
