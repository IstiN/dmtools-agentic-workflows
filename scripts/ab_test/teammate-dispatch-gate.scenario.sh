#!/usr/bin/env bash
# A/B: Decide whether this event is for the agent (the guard's dispatch gate)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init teammate-dispatch-gate.sh

seed_case() {
  mkdir -p fixtures seed/.dmtools
  cat > seed/.dmtools/config.js <<'CFG'
module.exports = { sm: { runners: {
  bug: "factory-agents/bug_development.json",
  story: "factory-agents/story_development.json",
  review: "factory-agents/pr_review.json",
  rework: "factory-agents/pr_rework.json",
} } };
CFG
  printf '{"state":"OPEN"}\n'                                    > fixtures/state-open.json
  printf '{"state":"CLOSED"}\n'                                  > fixtures/state-closed.json
  printf '{"state":"MISSING"}\n'                                 > fixtures/state-missing.json
  printf '{"title":"[bug] crash on save"}\n'                     > fixtures/title-bug.json
  printf '{"title":"Implement feature X"}\n'                     > fixtures/title-story.json
  printf '{"labels":[{"name":"status:In Development"}]}\n'       > fixtures/labels-dev-status.json
  printf '{"labels":[{"name":"agent:review"}]}\n'                > fixtures/labels-review.json
  printf '{"labels":[{"name":"agent:rework"}]}\n'                > fixtures/labels-rework.json
  printf '{"labels":[{"name":"agent:rework"},{"name":"status:In Rework"}]}\n' > fixtures/labels-rework-echo.json
  printf '{"labels":[{"name":"agent:skip"}]}\n'                  > fixtures/labels-skip.json
  printf '{"labels":[{"name":"blocked"}]}\n'                     > fixtures/labels-blocked.json
  printf '{"labels":[{"name":"agent:dev"}]}\n'                   > fixtures/labels-dev.json
  printf '{"labels":[]}\n'                                       > fixtures/labels-none.json
  printf '{"labels":[{"name":"blocked"}]}\n'                     > fixtures/pr-labels-blocked.json
  printf '{"labels":[]}\n'                                       > fixtures/pr-labels-none.json
  printf '{"permission":"admin"}\n'                              > fixtures/perm-admin.json
  printf '{"permission":"read"}\n'                               > fixtures/perm-read.json
  printf '{"assignees":[{"login":"ai-teammate"}]}\n'             > fixtures/assignees.json
  printf '[]\n'                                                  > fixtures/pr-list-empty.json

  local lbl=labels-none.json title=title-story.json prl=none st=open prs=pr-list-empty.json perm=admin
  case "${AB_CASE_ID}" in
    dispatch-dev-bug)                 title=title-bug.json ;;
    label-review-derive)              lbl=labels-review.json ;;
    label-rework-override-ok)         lbl=labels-rework.json ;;
    label-rework-override-denied)     lbl=labels-rework.json; perm=read ;;
    label-rework-echo-suppressed)     lbl=labels-rework-echo.json ;;
    assignee-dev-derive)              title=title-bug.json ;;
    in-flight-no-rederive)            lbl=labels-dev-status.json ;;
    agent-skip)                       lbl=labels-skip.json ;;
    blocked)                          lbl=labels-blocked.json ;;
    closed-issue)                     st=closed ;;
    missing-issue)                    st=missing ;;
    pr-anchored-review-blocked)       prl=blocked ;;
    pr-anchored-rework-denied)        perm=read ;;
    missing-config)                   rm -f seed/.dmtools/config.js ;;
  esac
  cat > gh_rules.tsv <<RULES
issue view.*--json state	json	${CASE}/fixtures/state-${st}.json
issue view.*--json labels.*join	json	${CASE}/fixtures/${lbl}
issue view.*--json assignees	json	${CASE}/fixtures/assignees.json
issue view.*--json title	json	${CASE}/fixtures/${title}
pr view.*--json state	json	${CASE}/fixtures/state-${st}.json
pr view.*--json labels	json	${CASE}/fixtures/pr-labels-${prl}.json
pr list	json	${CASE}/fixtures/${prs}
collaborators.*permission	json	${CASE}/fixtures/perm-${perm}.json
RULES
}

case_env() {
  echo "GH_TOKEN=stub-token"
  echo "AGENT_HANDLE=ai-teammate"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
  case "${AB_CASE_ID}" in
    dispatch-dev-bug)      echo "NUMBER=42"; echo "INPUT_LEG=dev" ;;
    dispatch-dev-story)    echo "NUMBER=42"; echo "INPUT_LEG=dev" ;;
    dispatch-review)       echo "NUMBER=42"; echo "INPUT_LEG=review" ;;
    dispatch-rework)       echo "NUMBER=42"; echo "INPUT_LEG=rework" ;;
    label-review-derive)   echo "NUMBER=42"; echo "ACTOR=labeled"; echo "SENDER=maintainer1" ;;
    label-rework-override-ok)      echo "NUMBER=42"; echo "ACTOR=labeled"; echo "SENDER=maintainer1" ;;
    label-rework-override-denied)  echo "NUMBER=42"; echo "ACTOR=labeled"; echo "SENDER=rand0m" ;;
    label-rework-echo-suppressed)  echo "NUMBER=42"; echo "ACTOR=labeled"; echo "SENDER=maintainer1" ;;
    assignee-dev-derive)   echo "NUMBER=42"; echo "ACTOR=assigned" ;;
    in-flight-no-rederive) echo "NUMBER=42"; echo "ACTOR=labeled"; echo "SENDER=maintainer1" ;;
    agent-skip)            echo "NUMBER=42"; echo "ACTOR=assigned" ;;
    blocked)               echo "NUMBER=42"; echo "ACTOR=assigned" ;;
    closed-issue)          echo "NUMBER=42"; echo "ACTOR=assigned" ;;
    missing-issue)         echo "NUMBER=99"; echo "ACTOR=assigned" ;;
    pr-anchored-review)    echo "PR_NUMBER=7" ;;
    pr-anchored-review-blocked) echo "PR_NUMBER=7" ;;
    pr-anchored-rework)    echo "PR_NUMBER=7"; echo "INPUT_REASON=Review findings require changes" ;;
    pr-anchored-rework-denied) echo "PR_NUMBER=7"; echo "INPUT_REASON=Review findings require changes"; echo "ACTOR=labeled"; echo "SENDER=rand0m" ;;
    both-anchors)          echo "NUMBER=42"; echo "PR_NUMBER=7" ;;
    no-anchor)             : ;;
    missing-config)        echo "NUMBER=42"; echo "INPUT_LEG=dev" ;;
  esac
}

extra_capture() {
  echo "── GITHUB_OUTPUT ──"
  cat gh_output
}

ab_case dispatch-dev-bug
ab_case dispatch-dev-story
ab_case dispatch-review
ab_case dispatch-rework
ab_case label-review-derive
ab_case label-rework-override-ok
ab_case label-rework-override-denied
ab_case label-rework-echo-suppressed
ab_case assignee-dev-derive
ab_case in-flight-no-rederive
ab_case agent-skip
ab_case blocked
ab_case closed-issue
ab_case missing-issue
ab_case pr-anchored-review
ab_case pr-anchored-review-blocked
ab_case pr-anchored-rework
ab_case pr-anchored-rework-denied
ab_case both-anchors
ab_case no-anchor
ab_case missing-config
ab_done
