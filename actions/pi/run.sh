#!/usr/bin/env bash
# Run pi against the triggering GitHub event and post its final message.
#
# Everything here is deterministic shell over structured data:
#   - the command is dispatched from the human's comment text (not model output)
#   - the answer is read from pi's documented --mode json event stream, never
#     scraped out of prose
set -euo pipefail

action_dir=${PI_ACTION_DIR:?}
repo_root=${GITHUB_WORKSPACE:-$PWD}
registry="$action_dir/../../profiles/profiles.json"
profiles_dir="$action_dir/../../profiles"
out_dir="${RUNNER_TEMP:-/tmp}/pi-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
mkdir -p "$out_dir"

events="$out_dir/pi-events.jsonl"
answer="$out_dir/answer.md"
context="$out_dir/context.md"
{ echo "events_file=$events"; echo "answer_file=$answer"; } >> "$GITHUB_OUTPUT"

event=${GITHUB_EVENT_PATH:?no event payload}

# ---------------------------------------------------------------- event facts
issue_number=$(jq -r '.issue.number // .pull_request.number // empty' "$event")
comment_body=$(jq -r '.comment.body // .review.body // empty' "$event")
issue_title=$(jq -r '.issue.title // .pull_request.title // empty' "$event")
issue_body=$(jq -r '.issue.body // .pull_request.body // empty' "$event")
actor=${GITHUB_ACTOR:-unknown}

[ -n "$issue_number" ] || { echo "::error::no issue or PR number in event payload"; exit 1; }

# ------------------------------------------------------------------- dispatch
# Longest-match a registered command token against the human's comment.
# Adding /pi-plan later is one entry in profiles.json plus one prompt file.
profile=${PI_PROFILE:-}
command_token=""
if [ "${PI_MODE:-comment}" = "comment" ]; then
  command_token=$(jq -rn \
    --slurpfile reg "$registry" \
    --arg body "$comment_body" \
    '($reg[0].commands) as $cmds
     | ($body | [splits("[[:space:]]+")]) as $tokens
     | [ $tokens[] | select($cmds[.] != null) ]
     | sort_by(length) | last // ""')
  # The workflow can only substring-match, so "https://claude.ai/..." reaches
  # us as a false trigger. A run needs a real command token, standing alone.
  if [ -z "$command_token" ]; then
    echo "no command token in the comment; nothing to do"
    exit 0
  fi
fi
if [ -z "$profile" ]; then
  if [ "${PI_MODE:-comment}" = "auto" ]; then
    profile=$(jq -r '.commands[.defaultAutoCommand] // "pi-auto"' "$registry")
  else
    profile=$(jq -r --arg c "$command_token" '.commands[$c]' "$registry")
  fi
fi
echo "profile=$profile"

prompt_file=$(jq -r --arg p "$profile" '.profiles[$p].prompt // empty' "$registry")
[ -n "$prompt_file" ] || { echo "::error::unknown profile: $profile"; exit 1; }
engine=$(jq -r --arg p "$profile" '.profiles[$p].engine // "pi"' "$registry")
mapfile -t extra_flags < <(jq -r --arg p "$profile" '.profiles[$p].flags[]? // empty' "$registry")
echo "engine=$engine"

# -------------------------------------------------------------- git / gh auth
# Scoped to the checkout, never --global: this script must be harmless if it is
# ever run outside the runner container.
git config --global --add safe.directory "$repo_root"
git -C "$repo_root" config user.name "pi-agent[bot]"
git -C "$repo_root" config user.email "pi-agent@users.noreply.github.com"
git -C "$repo_root" config \
  "url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf" \
  "https://github.com/"

# ----------------------------------------------------------- generated context
{
  echo "## This run"
  echo
  echo "- Repository: \`$GITHUB_REPOSITORY\` (checked out at \`$repo_root\`, branch \`$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)\`)"
  echo "- Thread: #$issue_number — $issue_title"
  echo "- Triggered by: \`$actor\` via \`$GITHUB_EVENT_NAME\`"
  echo "- Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  echo
  echo "### Thread body"
  echo
  echo "$issue_body"
} > "$context"

if [ "${PI_MODE:-comment}" = "auto" ]; then
  query="Handle issue #$issue_number as described in your instructions."
else
  # The comment goes to the engine as written, minus a leading command token:
  # Claude Code reads a prompt that starts with "/" as one of its own slash
  # commands. A token anywhere else is left alone.
  query="$comment_body"
  trimmed=${query#"${query%%[![:space:]]*}"}
  case "$trimmed" in
    "$command_token"|"$command_token"[[:space:]]*)
      query=${trimmed#"$command_token"}
      query=${query#"${query%%[![:space:]]*}"}
      ;;
  esac
  # A bare command with nothing after it still needs a task.
  if ! printf '%s' "$query" | grep -q "[^[:space:]]"; then
    query="Respond to thread #$issue_number as described in your instructions."
  fi
fi

# ---------------------------------------------------------------- run engine
# Each engine gets the same two system-prompt appends and the same query, and
# leaves its final answer in $answer. Both read that answer out of the engine's
# own structured output, never out of prose.
cd "$repo_root"
stderr_log="$out_dir/pi-stderr.log"

case "$engine" in
  pi)
    set +e
    pi --mode json -p -a \
      --no-session \
      --append-system-prompt "$profiles_dir/$prompt_file" \
      --append-system-prompt "$context" \
      ${extra_flags[@]+"${extra_flags[@]}"} \
      -- "$query" < /dev/null > "$events" 2> "$stderr_log"
    pi_rc=$?
    set -e
    # message_end carries the final authoritative assistant message (docs/json.md).
    jq -rs '
      [ .[]
        | select(.type == "message_end")
        | .message
        | select(.role == "assistant")
      ]
      | last
      | (.content // [])
      | map(select(.type == "text") | .text)
      | join("\n")
    ' "$events" > "$answer" || true
    ;;
  claude)
    : "${CLAUDE_CODE_OAUTH_TOKEN:?claude engine needs a CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)}"
    set +e
    claude -p --output-format json \
      --permission-mode bypassPermissions \
      --append-system-prompt "$(cat "$profiles_dir/$prompt_file" "$context")" \
      ${extra_flags[@]+"${extra_flags[@]}"} \
      -- "$query" < /dev/null > "$events" 2> "$stderr_log"
    pi_rc=$?
    set -e
    # -p --output-format json emits one object; .result is the final answer,
    # and is_error marks a failed run (the text then describes the failure).
    jq -r 'select(.is_error != true) | .result // empty' "$events" > "$answer" || true
    ;;
  *)
    echo "::error::unknown engine: $engine"
    exit 1
    ;;
esac
tail -n 40 "$stderr_log" >&2 || true

# An engine can exit 0 after the provider rejected the request, so failure is
# read from its own structured error fields.
case "$engine" in
  pi)
    pi_error=$(jq -rs '
      [ .[]
        | select(.type == "message_end")
        | .message
        | select(.role == "assistant")
      ]
      | last
      | select(.stopReason == "error")
      | .errorMessage // "unknown error"
    ' "$events" 2>/dev/null || true)
    ;;
  claude)
    pi_error=$(jq -r 'select(.is_error == true) | .result // .subtype // "unknown error"' \
      "$events" 2>/dev/null || true)
    ;;
esac

# A whitespace-only answer counts as no answer.
if ! grep -q "[^[:space:]]" "$answer"; then
  {
    echo "$engine produced no final message (exit $pi_rc)."
    # Structured provider error if the engine got far enough to record one,
    # otherwise its stderr (startup failures such as a missing login).
    reason=$pi_error
    if [ -z "$reason" ] && [ -s "$out_dir/pi-stderr.log" ]; then
      reason=$(tail -n 20 "$out_dir/pi-stderr.log")
    fi
    if [ -n "$reason" ]; then
      echo
      echo '```'
      echo "$reason"
      echo '```'
    fi
    echo
    echo "[Run log]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID) — the raw event stream is attached to that run as an artifact."
  } > "$answer"
  if [ "$pi_rc" -eq 0 ]; then pi_rc=1; fi
fi

# GitHub rejects comments over 65536 characters.
if [ "$(wc -c < "$answer")" -gt 65000 ]; then
  head -c 64000 "$answer" > "$answer.cut"
  printf '\n\n_(truncated — full output in the [run artifacts](%s/%s/actions/runs/%s))_\n' \
    "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" >> "$answer.cut"
  mv "$answer.cut" "$answer"
fi

# Marker so a reply that happens to mention a command cannot retrigger the
# workflow. Workflows skip any comment containing it; humans never see it.
printf '\n\n<!-- agent-reply -->\n' >> "$answer"

if [ "${PI_POST_COMMENT:-true}" = "true" ]; then
  jq -n --rawfile body "$answer" '{body: $body}' \
    | gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$issue_number/comments" --input -
fi

exit "$pi_rc"
