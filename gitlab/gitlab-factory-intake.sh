if [ "${1:-}" = --develop ]; then
  iid="${2:?Issue IID}"
  config="${3:?Development runner}"
  base_sha=$(git rev-parse HEAD)
  run_agent "$config" --inputTicketId "$iid"
  publish_issue_changes "$iid" "$base_sha"
  exit 0
fi

. .dmtools/scripts/gitlab-factory-common.sh
factory_identity dev
payload_kind=''
payload_iid=''
if [ "${DMTOOLS_FACTORY_TRIGGER:-}" = issue_webhook ]; then
  : "${TRIGGER_PAYLOAD:?GitLab webhook payload is required}"
  payload_kind=$(jq -er '.object_kind | select(. == "issue" or . == "merge_request")' "$TRIGGER_PAYLOAD")
  payload_iid=$(jq -er '.object_attributes.iid | numbers' "$TRIGGER_PAYLOAD")
  if jq -e --arg kind "$payload_kind" '
    if $kind == "issue" then
      ((.changes // {}) | keys) as $keys |
      (.object_attributes.action != "open" and .object_attributes.action != "reopen") and (
      ($keys | length > 0 and all(. == "description" or . == "updated_at")) or
      ((.changes.labels? != null) and
       (((.changes.labels.current // []) | map(.title // .name)) -
        ((.changes.labels.previous // []) | map(.title // .name)) |
        all(. != "agent:dev" and . != "agent:review" and . != "agent:rework"))))
    else
      .object_attributes.action != "open" and
      .object_attributes.action != "reopen" and
      .object_attributes.oldrev == null and
      (((.changes.labels.current // []) | map(.title // .name)) -
       ((.changes.labels.previous // []) | map(.title // .name)) |
       all(. != "agent:review" and . != "agent:rework"))
    end
  ' "$TRIGGER_PAYLOAD" >/dev/null; then
    echo "Ignoring factory progress/status echo; no actionable change."
    exit 0
  fi
fi

if [ -n "${DMTOOLS_MR_IID:-}" ]; then
  bash .dmtools/scripts/gitlab-factory-lifecycle.sh run "$DMTOOLS_MR_IID" '' "${DMTOOLS_FACTORY_LEG:-}"
  exit 0
fi
if [ "$payload_kind" = merge_request ]; then
  mr=$(factory_api GET "/projects/$CI_PROJECT_ID/merge_requests/$payload_iid")
  if printf '%s' "$mr" | jq -e '.source_branch | startswith("ai/issue-")' >/dev/null; then
    force=$(printf '%s' "$mr" | jq -r 'if any(.labels[]?; . == "agent:rework") then "rework" elif any(.labels[]?; . == "agent:review") then "review" else "" end')
    bash .dmtools/scripts/gitlab-factory-lifecycle.sh run "$payload_iid" '' "$force"
  fi
  exit 0
fi

issues=$(factory_list "/projects/$CI_PROJECT_ID/issues?state=opened")
identity=$(factory_api GET /user)
machine=$(printf '%s' "$identity" | jq -er '.username | strings')
issue_ids=$(printf '%s' "$issues" | jq -r --arg machine "$machine" --arg iid "$payload_iid" '
  .[] | select($iid == "" or (.iid | tostring) == $iid)
  | select(all(.labels[]?; . != "agent:skip" and . != "blocked" and . != "needs-human"))
  | select(
      any(.labels[]?; . == "agent:review" or . == "agent:rework") or
      (all(.labels[]?; . != "ai_developed" and . != "ai_pr_reviewed") and
        (any(.labels[]?; . == "agent:dev") or any(.assignees[]?; .username == $machine))))
  | .iid')
while IFS= read -r iid; do
  [ -n "$iid" ] || continue
  issue=$(factory_api GET "/projects/$CI_PROJECT_ID/issues/$iid")
  related=$(factory_list "/projects/$CI_PROJECT_ID/issues/$iid/related_merge_requests")
  count=$(printf '%s' "$related" | jq '[.[] | select(.state == "opened")] | length')
  if [ "$count" -gt 1 ]; then
    echo "Multiple open MRs are linked to issue #$iid; refusing to guess." >&2
    exit 1
  fi
  force=$(printf '%s' "$issue" | jq -r 'if any(.labels[]?; . == "agent:rework") then "rework" elif any(.labels[]?; . == "agent:review") then "review" else "" end')
  if [ "$count" -eq 1 ]; then
    mr_iid=$(printf '%s' "$related" | jq -er '.[] | select(.state == "opened") | .iid')
  else
    if [ -n "$force" ]; then
      echo "Review/rework requires an existing open MR linked to issue #$iid." >&2
      exit 1
    fi
    config='.dmtools/runners/fa-story-dev.json'
    if printf '%s' "$issue" | jq -e 'any(.labels[]?; . == "bug")' >/dev/null; then
      config='.dmtools/runners/fa-bug-dev.json'
    fi
    export DMTOOLS_FACTORY_MR_FILE
    DMTOOLS_FACTORY_MR_FILE=$(mktemp)
    if ! bash .dmtools/scripts/gitlab-factory-job.sh "$iid" dev \
      bash .dmtools/scripts/gitlab-factory-poll-issues.sh --develop "$iid" "$config"; then
      rm -f "$DMTOOLS_FACTORY_MR_FILE"
      factory_api PUT "/projects/$CI_PROJECT_ID/issues/$iid" --data-urlencode 'add_labels=needs-human' >/dev/null
      exit 1
    fi
    mr_iid=$(cat "$DMTOOLS_FACTORY_MR_FILE")
    rm -f "$DMTOOLS_FACTORY_MR_FILE"
    [[ "$mr_iid" =~ ^[0-9]+$ ]] || { echo "Development did not return a created MR IID." >&2; exit 1; }
  fi
  factory_labels "$mr_iid" "$iid" 'ai_developed,agent:review' agent:dev
  bash .dmtools/scripts/gitlab-factory-lifecycle.sh run "$mr_iid" "$iid" "$force"
done <<< "$issue_ids"

if [ -z "$payload_kind" ]; then
  mrs=$(factory_list "/projects/$CI_PROJECT_ID/merge_requests?state=opened")
  mr_ids=$(printf '%s' "$mrs" | jq -r '
    .[] | select(.source_branch | startswith("ai/issue-"))
    | select(all(.labels[]?; . != "needs-human" and . != "blocked" and . != "agent:skip"))
    | .iid')
  while IFS= read -r mr_iid; do
    [ -n "$mr_iid" ] || continue
    bash .dmtools/scripts/gitlab-factory-lifecycle.sh run "$mr_iid"
  done <<< "$mr_ids"
fi
