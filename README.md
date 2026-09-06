# gh-runners-docker

Persistent self-hosted GitHub Actions runners as Docker containers, plus a
container that runs a coding agent, so `/pi <query>` or `/claude <query>` in an
issue or PR comment gets an answer as a comment.

Two engines are installed side by side: [pi](https://github.com/earendil-works/pi-mono)
(provider-agnostic, credentials in a Docker volume) and Claude Code
(first-party, so a Claude subscription covers headless CI use; authenticates
from a `CLAUDE_CODE_OAUTH_TOKEN` secret). The command decides which one runs.

Workflows pick a container by **runner label**:

| Label | Container | Purpose |
|---|---|---|
| `base` | `Dockerfile.base` | Plain runner (git, gh, jq, ripgrep). Token only, no agent. |
| `agent` | `Dockerfile.agent` | Interactive `/pi` and `/claude` comment replies. |
| `agent-worker` | `Dockerfile.agent` | Autonomous label-driven runs, so long jobs never block comment replies. |

```yaml
runs-on: [self-hosted, agent]
```

## Setup on a new machine

```bash
cp envs/example.env envs/<repo>.env    # GH_PAT (classic, `repo` scope) + REPO_URL
scripts/up.sh <repo>                   # build images, register 3 runners for that repo
scripts/login-pi.sh                    # once per machine, only for the pi engine
scripts/status.sh                      # verify pi auth in the shared volume
```

`scripts/up.sh <repo>` uses compose project `runners-<repo>`, so several repos'
runner sets coexist on one machine. Runner registration lives in named volumes
with `DISABLE_AUTOMATIC_DEREGISTRATION=true`: restarting a container reuses the
same runner instead of re-registering.

After an ungraceful stop a runner can log `A session for this runner already
exists` and stay `offline` while GitHub still holds the old session. It retries
on its own; `docker restart <container>` clears it immediately.

pi's credentials live in the shared `pi-agent-home` Docker volume, never in an
env var and never bind-mounted from the host. The OAuth token refreshes itself.

> pi is a third-party harness, so a Claude Pro/Max login there draws on **extra
> usage**, not plan limits — fund it at <https://claude.ai/settings/usage> or
> every `/pi` run fails with a 400. `/login` an API-key provider instead, or use
> the `/claude` commands, which run first-party Claude Code on the subscription.

## Wiring up a repository

Copy the files from `templates/` into the repo's `.github/workflows/`, then:

```bash
gh variable set PI_DEVS --repo <owner/repo> --body '["your-login"]'
gh secret   set PI_GH_TOKEN --repo <owner/repo>     # PAT: push + PR
claude setup-token | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner/repo>
gh label create pi-auto --repo <owner/repo>
```

`PI_GH_TOKEN` rather than `GITHUB_TOKEN` because pull requests opened with
`GITHUB_TOKEN` do not trigger further workflow runs.

## How the agent commands work

`actions/pi` is a composite action; `actions/pi/run.sh` does four deterministic
things and leaves everything else to the agent:

1. **Dispatch** — tokenises the human's comment and longest-matches it against
   the keys in `profiles/profiles.json`. Human text, not model output.
2. **Context** — generates a markdown block (repo, thread, actor, branch, run
   URL, thread body) and appends it to the system prompt.
3. **Run** — the profile's `engine` decides the command: `pi --mode json -p -a`
   or `claude -p --output-format json`. Both get the same two system-prompt
   appends and the whole comment passed through verbatim as the query.
4. **Extract** — reads the final message out of the engine's structured output:
   pi's `message_end` event, or Claude Code's `.result` field. No regex over
   model prose. Failures come from the same structures (`stopReason`/
   `errorMessage`, `is_error`), because either engine can exit 0 after the
   provider rejected the request.

### Adding a command

Add one entry to `profiles/profiles.json` and one prompt file next to it:

```json
"commands": { "/pi": "pi", "/pi-plan": "pi-plan" },
"profiles": { "pi-plan": { "engine": "pi", "prompt": "plan.md", "flags": ["-t", "read,grep,find,ls"] } }
```

No code changes. `flags` are passed straight to the engine, so a read-only or
cheaper-model profile needs no branching in the script.

### Prompt profiles

`profiles/*.md` are appended to the engine's system prompt. They state the output
contract (final message is posted verbatim, GFM, no `#`/`##`, comment-sized,
long output in `<details>`) and the default workflow (design in the issue first,
build on a feature branch behind a draft PR after a human confirms) — and then
state explicitly that the human's instructions override all of it. Nothing is
enforced in code, so the agent stays agentic.

## Security

- Keep self-hosted runners off public repos that accept fork PRs: a fork's
  workflow would execute in your container, on your machine. This repo is
  public but has no self-hosted workflows of its own.
- Neither engine is sandboxed, and both run with permission checks off. The
  container is the boundary: no host bind mounts, no host `~/.pi/agent`, no
  Docker socket.
- Issue and comment text is untrusted input to an agent that can push. `/pi` is
  gated on an allowlist of logins, and `PI_GH_TOKEN` should carry the smallest
  scope that still allows push and PR.
