# gh-runners-docker

Persistent self-hosted GitHub Actions runners as Docker containers, plus a
container that runs the [pi coding agent](https://github.com/earendil-works/pi-mono)
so `/pi <query>` in an issue or PR comment gets an answer as a comment.

Workflows pick a container by **runner label**:

| Label | Container | Purpose |
|---|---|---|
| `base` | `Dockerfile.base` | Plain runner (git, gh, jq, ripgrep). Token only, no agent. |
| `pi-agent` | `Dockerfile.pi` | Interactive `/pi` comment replies. |
| `pi-worker` | `Dockerfile.pi` | Autonomous label-driven runs, so long jobs never block `/pi`. |

```yaml
runs-on: [self-hosted, pi-agent]
```

## Setup on a new machine

```bash
cp envs/example.env envs/<repo>.env    # GH_PAT (classic, `repo` scope) + REPO_URL
scripts/up.sh <repo>                   # build images, register 3 runners for that repo
scripts/login-pi.sh                    # once per machine: /login -> Claude Pro/Max
scripts/status.sh                      # verify pi auth in the shared volume
```

`scripts/up.sh <repo>` uses compose project `runners-<repo>`, so several repos'
runner sets coexist on one machine. Runner registration lives in named volumes
with `DISABLE_AUTOMATIC_DEREGISTRATION=true`: restarting a container reuses the
same runner instead of re-registering.

pi's credentials live in the shared `pi-agent-home` Docker volume, never in an
env var and never bind-mounted from the host. The OAuth token refreshes itself.

> Claude Pro/Max usage from third-party harnesses draws on **extra usage**, not
> plan limits — enable it at <https://claude.ai/settings/usage> or every run
> fails with a 400. Alternatively `/login` with an API-key provider instead.

## Wiring up a repository

Copy the files from `templates/` into the repo's `.github/workflows/`, then:

```bash
gh variable set PI_DEVS --repo <owner/repo> --body '["your-login"]'
gh secret   set PI_GH_TOKEN --repo <owner/repo>     # PAT: push + PR
gh label create pi-auto --repo <owner/repo>
```

`PI_GH_TOKEN` rather than `GITHUB_TOKEN` because pull requests opened with
`GITHUB_TOKEN` do not trigger further workflow runs.

## How `/pi` works

`actions/pi` is a composite action; `actions/pi/run.sh` does four deterministic
things and leaves everything else to the agent:

1. **Dispatch** — tokenises the human's comment and longest-matches it against
   the keys in `profiles/profiles.json`. Human text, not model output.
2. **Context** — generates a markdown block (repo, thread, actor, branch, run
   URL, thread body) and appends it to the system prompt.
3. **Run** — `pi --mode json -p -a --append-system-prompt <profile> …` with the
   whole comment passed through verbatim as the query.
4. **Extract** — reads the final assistant message out of pi's documented JSON
   event stream (`message_end`) with `jq`, and posts it verbatim as a comment.
   No regex over model prose; provider failures are detected from the message's
   `stopReason`/`errorMessage` fields, which pi reports even when it exits 0.

### Adding a command

Add one entry to `profiles/profiles.json` and one prompt file next to it:

```json
"commands": { "/pi": "pi", "/pi-plan": "pi-plan" },
"profiles": { "pi-plan": { "prompt": "pi-plan.md", "flags": ["-t", "read,grep,find,ls"] } }
```

No code changes. `flags` are passed straight to `pi`, so a read-only or
cheaper-model profile needs no branching in the script.

### Prompt profiles

`profiles/*.md` are appended to pi's system prompt. They state the output
contract (final message is posted verbatim, GFM, no `#`/`##`, comment-sized,
long output in `<details>`) and the default workflow (design in the issue first,
build on a feature branch behind a draft PR after a human confirms) — and then
state explicitly that the human's instructions override all of it. Nothing is
enforced in code, so pi stays agentic.

## Security

- Keep self-hosted runners off public repos that accept fork PRs: a fork's
  workflow would execute in your container, on your machine. This repo is
  public but has no self-hosted workflows of its own.
- pi has no sandbox. The container is the boundary: no host bind mounts, no
  host `~/.pi/agent`, no Docker socket.
- Issue and comment text is untrusted input to an agent that can push. `/pi` is
  gated on an allowlist of logins, and `PI_GH_TOKEN` should carry the smallest
  scope that still allows push and PR.
