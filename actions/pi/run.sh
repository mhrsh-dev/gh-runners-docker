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
if [ -z "$profile" ]; then
  if [ "${PI_MODE:-comment}" = "auto" ]; then
    profile=$(jq -r '.commands["/pi-auto"] // "pi-auto"' "$registry")
  else
    profile=$(jq -rn \
      --slurpfile reg "$registry" \
      --arg body "$comment_body" \
      '($reg[0].commands) as $cmds
       | ($body | [splits("[[:space:]]+")]) as $tokens
       | [ $tokens[] | select($cmds[.] != null) ]
       | sort_by(length) | last as $hit
       | if $hit then $cmds[$hit] else $cmds[$reg[0].defaultCommand] end')
  fi
fi
echo "profile=$profile"

prompt_file=$(jq -r --arg p "$profile" '.profiles[$p].prompt // empty' "$registry")
[ -n "$prompt_file" ] || { echo "::error::unknown profile: $profile"; exit 1; }
mapfile -t extra_flags < <(jq -r --arg p "$profile" '.profiles[$p].flags[]? // empty' "$registry")

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
  # The comment goes to pi verbatim, command token and all. No extraction, so a
  # human can phrase the request however they like.
  query="$comment_body"
fi

# ------------------------------------------------------------------- run pi
cd "$repo_root"
set +e
pi --mode json -p -a \
  --no-session \
  --append-system-prompt "$profiles_dir/$prompt_file" \
  --append-system-prompt "$context" \
  ${extra_flags[@]+"${extra_flags[@]}"} \
  -- "$query" < /dev/null > "$events" 2> "$out_dir/pi-stderr.log"
pi_rc=$?
set -e
tail -n 40 "$out_dir/pi-stderr.log" >&2 || true

# ----------------------------------------------------- final message (structured)
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

# pi exits 0 even when the provider rejected the request, so failure is read
# from the last assistant message's structured stopReason/errorMessage.
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

# A whitespace-only answer counts as no answer.
if ! grep -q "[^[:space:]]" "$answer"; then
  {
    echo "pi produced no final message (exit $pi_rc)."
    # Structured provider error if pi got far enough to record one, otherwise
    # whatever it said on stderr (startup failures such as a missing login).
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

if [ "${PI_POST_COMMENT:-true}" = "true" ]; then
  jq -n --rawfile body "$answer" '{body: $body}' \
    | gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$issue_number/comments" --input -
fi

exit "$pi_rc"
