#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Decide whether this event is for the agent) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  # Anchor validation (#687): exactly one of issue|pr.
  if [ -n "$NUMBER" ] && [ -n "$PR_NUMBER" ]; then
    echo "::error::both issue ($NUMBER) and pr ($PR_NUMBER) given — exactly one anchor allowed"
    exit 1
  fi
  if [ -z "$NUMBER" ] && [ -z "$PR_NUMBER" ]; then
    echo "::error::no anchor — pass either issue or pr"
    exit 1
  fi

  # ── runners come from the TARGET repo (.dmtools/config.js) ──
  # The factory ships no repo-specific runners: sm.runners maps
  # legs to configs in this repository (see the integration guide,
  # "Overriding agents per repository"). dev covers bug and story.
  if [ ! -f .dmtools/config.js ]; then
    echo "::error::.dmtools/config.js not found — the factory needs sm.runners to know this repo's agents (docs/machine-factory-integration.md §5a)"
    exit 1
  fi
  ovr="$(node -e "try{const c=require('./.dmtools/config.js');const r=(c.sm&&c.sm.runners)||{};console.log([r.bug||r.dev||'',r.story||r.dev||'',r.review||'',r.rework||''].join('\t'))}catch(e){}" 2>/dev/null || true)"
  if [ -z "$ovr" ]; then
    echo "::error::sm.runners missing in .dmtools/config.js (bug/story[/dev], review, rework → runner config paths)"
    exit 1
  fi
  RUNNER_BUG="$(echo "$ovr" | cut -f1)"
  RUNNER_STORY="$(echo "$ovr" | cut -f2)"
  RUNNER_REVIEW="$(echo "$ovr" | cut -f3)"
  RUNNER_REWORK="$(echo "$ovr" | cut -f4)"
  echo "→ runners (from .dmtools/config.js): bug=${RUNNER_BUG:--} story=${RUNNER_STORY:--} review=${RUNNER_REVIEW:--} rework=${RUNNER_REWORK:--}"

  # Owner override gate (#544 owner rule, issue comment 3): a MANUAL
  # agent:rework label IS the explicit override — it fires rework on
  # ANY PR (machine or guest, with or without a local issue). But the
  # machine NEVER self-triggers rework on guest PRs, and a random
  # external labeler must not burn factory tokens. Where the
  # `labeled` event sender is known, gate the override on its repo
  # permission (write/admin/maintain). Schedule-scan dispatches and
  # non-labeled events carry no meaningful actor — the label is
  # trusted as-is (the SM consumed/verified it upstream).
  rework_override_ok() {
    if [ "$ACTOR" != "labeled" ] || [ -z "$SENDER" ]; then
      return 0
    fi
    perm="$(gh api "repos/$GITHUB_REPOSITORY/collaborators/$SENDER/permission" -q .permission 2>/dev/null || true)"
    case "$perm" in
      admin|maintain|write) return 0 ;;
      *)
        echo "::warning::agent:rework by '$SENDER' (permission: ${perm:-none}) — the owner override requires write/admin; skipping (never fails the cycle, #544)"
        return 1
        ;;
    esac
  }

  # ── PR-anchored dispatch (#687): the PR is the anchor. Review was
  # the only leg defined for it — #544 extends the branch to REWORK:
  # a labeled PR with no resolvable LOCAL issue anchors on the PR
  # itself (pr-<N>, owner rule 3) and the rework runner derives its
  # context from the PR (review findings, failing checks).
  if [ -n "$PR_NUMBER" ]; then
    state="$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --json state -q .state 2>/dev/null || true)"
    if [ -z "$state" ]; then
      # #544 rule 2: an unresolvable anchor is a warn-and-skip —
      # never exit 1. One bad number must not stall the machine loop.
      echo "::warning::PR #$PR_NUMBER could not be resolved in $GITHUB_REPOSITORY — skipping (clean no-op, #544)"
      echo "run=false" >> "$GITHUB_OUTPUT"
      exit 0
    fi
    if [ "$state" != "OPEN" ]; then
      echo "run=false" >> "$GITHUB_OUTPUT"
      echo "→ PR #$PR_NUMBER is ${state} — not for the agent"
      exit 0
    fi
    # 'blocked' = human hold (fa #939): the freeze switch applies to
    # PR-anchored legs too — a frozen PR gets no review/rework run.
    pr_blocked="$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" \
      --json labels -q '([.labels[].name] | index("blocked")) != null' 2>/dev/null || echo false)"
    if [ "$pr_blocked" = "true" ]; then
      echo "run=false" >> "$GITHUB_OUTPUT"
      echo "→ PR #$PR_NUMBER carries blocked — human hold, the machine skips it entirely"
      exit 0
    fi
    leg="$INPUT_LEG"
    if [ -z "$leg" ] && echo "$INPUT_REASON" | grep -qi 'rework'; then
      leg="rework"
    fi
    if [ "$leg" = "rework" ]; then
      if ! rework_override_ok; then
        echo "run=false" >> "$GITHUB_OUTPUT"
        exit 0
      fi
      echo "run=true" >> "$GITHUB_OUTPUT"
      echo "runner=$RUNNER_REWORK" >> "$GITHUB_OUTPUT"
      echo "config=factory-agents/pr_rework.json" >> "$GITHUB_OUTPUT"
      echo "kind=rework" >> "$GITHUB_OUTPUT"
      echo "anchor=pr-${PR_NUMBER}" >> "$GITHUB_OUTPUT"
      echo "→ PR-anchored REWORK of #$PR_NUMBER (reason=${INPUT_REASON:-<none>}, #544)"
      exit 0
    fi
    echo "run=true" >> "$GITHUB_OUTPUT"
    echo "runner=$RUNNER_REVIEW" >> "$GITHUB_OUTPUT"
    echo "config=factory-agents/pr_review.json" >> "$GITHUB_OUTPUT"
    echo "kind=review" >> "$GITHUB_OUTPUT"
    echo "anchor=pr-${PR_NUMBER}" >> "$GITHUB_OUTPUT"
    echo "→ PR-anchored review of #$PR_NUMBER (reason=${INPUT_REASON:-<none>})"
    exit 0
  fi
  echo "anchor=gh-${NUMBER}" >> "$GITHUB_OUTPUT"

  # RACE GUARD (live: agents #934, 2026-10-16 — an `assigned` and a
  # `labeled` event for one issue BOTH passed the fresh-label refresh
  # before either applied its status labels; the per-issue concurrency
  # group (cancel-in-progress: false) queued both — duplicate legs).
  # An EVENT-triggered run self-cancels when a sibling leg already
  # carries the anchor: in_progress, or queued with an EARLIER run id
  # (the elder twin wins). Explicit dispatches (inputs.leg) always win
  # and never self-cancel. Title match is "#N" — the issues-event echo
  # shape ("teammate: issues #N"); PR-anchored dispatches spell
  # pr-N/gh-N and do not collide.
  if [ -z "${INPUT_LEG:-}" ]; then
    sibling="$(gh run list --repo "${GITHUB_REPOSITORY}" \
      --workflow "${GITHUB_WORKFLOW}" --limit 30 \
      --json databaseId,status,displayTitle \
      --jq ".[] | select(.databaseId != ${GITHUB_RUN_ID}) \
            | select(.status == \"in_progress\" or (.status == \"queued\" and .databaseId < ${GITHUB_RUN_ID})) \
            | select(.displayTitle | contains(\"#${NUMBER}\")) | .databaseId" \
      | head -1)"
    if [ -n "$sibling" ]; then
      echo "::notice::race guard: sibling run ${sibling} already carries #${NUMBER} — self-cancelling (event echo)"
      gh run cancel "${GITHUB_RUN_ID}" --repo "${GITHUB_REPOSITORY}" || true
      sleep 10
      exit 0
    fi
  fi

  # ALWAYS refresh labels/assignees from the API — not just for
  # explicit dispatches. Event-triggered runs (issues:assigned,
  # labeled, ...) sit QUEUED behind the per-issue concurrency group,
  # and the github.event.issue payload they carry is a snapshot from
  # trigger time: a guard that trusts it misses labels the
  # already-running leg has since applied (status:In Development,
  # status:In Rework) and dispatches a duplicate dev/rework leg on
  # top of the live one (live: dmtools-dart run 36252718919 for #257;
  # a duplicate rework dispatch for #259). The event payload is only
  # a fallback when the API read itself fails.
  if fresh_labels="$(gh issue view "$NUMBER" --repo "$GITHUB_REPOSITORY" --json labels -q '[.labels[].name] | join(" ")')" \
    && fresh_assignees="$(gh issue view "$NUMBER" --repo "$GITHUB_REPOSITORY" --json assignees -q '[.assignees[].login] | join(" ")')"; then
    LABELS="$fresh_labels"
    ASSIGNEES="$fresh_assignees"
  else
    echo "::warning::labels/assignees refresh failed for #$NUMBER — falling back to the (possibly stale) event payload"
  fi
  if [ -n "$INPUT_LEG" ]; then
    echo "→ dispatch: leg=$INPUT_LEG reason=${INPUT_REASON:-<none>}"
  fi
  # Closed issues are terminal: no agent runs on them. #544 rule 2:
  # a FAILED resolution (404 — missing issue or cross-repo ref like
  # 'dm.ai #601') is a warn-and-skip, never exit 1 — one bad anchor
  # must not turn the whole SM cycle red every 15 min.
  state="$(gh issue view "$NUMBER" --repo "$GITHUB_REPOSITORY" --json state -q .state 2>/dev/null || true)"
  if [ -z "$state" ]; then
    echo "::warning::issue #$NUMBER could not be resolved in $GITHUB_REPOSITORY (missing or cross-repo ref) — skipping this leg (clean no-op, #544)"
    echo "run=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  if [ "$state" != "OPEN" ]; then
    echo "run=false" >> "$GITHUB_OUTPUT"
    echo "→ issue #$NUMBER is ${state} — not for the agent"
    exit 0
  fi
  # agent:skip — hard opt-out for smoke/verification tickets.
  if echo "$LABELS" | grep -qw "agent:skip"; then
    echo "run=false" >> "$GITHUB_OUTPUT"
    echo "→ issue #$NUMBER carries agent:skip — agent bypassed"
    exit 0
  fi
  # 'blocked' = human hold (fa #939): the official freeze switch —
  # no leg starts on a frozen item, whatever the event (assignment,
  # any label echo). Same label the SM engine and the machine-SM
  # reconciler honor; removing it returns the item to the loop.
  if echo "$LABELS" | grep -qw "blocked"; then
    echo "run=false" >> "$GITHUB_OUTPUT"
    echo "→ issue #$NUMBER carries blocked — human hold, the machine skips it entirely"
    exit 0
  fi
  runner=""
  slot=""
  if [ -n "$INPUT_LEG" ]; then
    case "$INPUT_LEG" in
      rework) runner="$RUNNER_REWORK"; slot="rework" ;;
      review) runner="$RUNNER_REVIEW"; slot="review" ;;
      dev)
        title="$(gh issue view "$NUMBER" --repo "$GITHUB_REPOSITORY" --json title -q .title)"
        if echo "$title" | grep -qiE '^\[?bug\]' \
          || echo "$LABELS" | grep -qwi "bug"; then
          runner="$RUNNER_BUG"; slot="bug"
        else
          runner="$RUNNER_STORY"; slot="story"
        fi
        ;;
    esac
  elif echo "$LABELS" | grep -qw "agent:rework" \
    && ! echo "$LABELS" | grep -q 'status:In Rework'; then
    # status:In Rework = a rework leg already runs/ran — its own
    # status transition echoes back as a `labeled` event and would
    # re-derive the same leg on top of itself.
    # #544: manual agent:rework is the owner override — it fires
    # rework even from a `labeled` event, but only when the labeler
    # has write/admin (see rework_override_ok). Without permission
    # the override is ignored (runner stays empty → clean skip).
    if rework_override_ok; then
      runner="$RUNNER_REWORK"
    fi
  elif echo "$LABELS" | grep -qw "agent:review"; then
    # status:In Review is NOT an in-flight marker here — the DEV leg
    # sets it as the "ready for review" invitation, so blocking on it
    # kills the label-echo review trigger (live: dmtools-dart gh-182).
    # Real duplicate protection is the per-issue concurrency group.
    runner="$RUNNER_REVIEW"; slot="review"
  elif echo "$LABELS" | grep -qE 'status:In Development|status:In Review|status:In Rework|in progress|ai_developed|ai_pr_reviewed|_wip|rework-round-'; then
    # Dev is a FRESH handoff only: once the loop has touched the
    # issue, later `labeled` events (the dev leg's OWN status:In
    # Development transition, SM backfill labels, ...) would
    # re-derive dev and queue a duplicate leg on top of the
    # running/finished one (live: fa gh-746 — the assigned-handoff
    # dev ran while its status-label echo queued a second dev).
    # The SM owns the loop from there; explicit dispatches
    # (inputs.leg) bypass this derive branch entirely.
    :
  elif echo "$ASSIGNEES" | grep -qw "$AGENT_HANDLE" \
    || echo "$LABELS" | grep -qw "agent:dev"; then
    title="$(gh issue view "$NUMBER" --repo "$GITHUB_REPOSITORY" --json title -q .title)"
    if echo "$title" | grep -qiE '^\[?bug\]' \
      || echo "$LABELS" | grep -qwi "bug"; then
      runner="$RUNNER_BUG"; slot="bug"
    else
      runner="$RUNNER_STORY"; slot="story"
    fi
  fi
  if [ -n "$runner" ]; then
    # Parent agent config — fa-session.sh derives the session group
    # from its basename (dev-write vs dev-review).
    # Parent pipeline by SLOT — custom runners (config overrides)
    # inherit the leg's pipeline, so a repo can swap the agent
    # without losing session/verdict semantics. The value below is
    # the LEGACY tree path; the teammate job re-resolves it pack-first
    # (Wave 2: an unpacked pack's launch.json WINS — see the
    # "Resolve parent config" step; this fallback keeps old pins
    # working when no Wave-2 pack is unpacked).
    case "$slot" in
      bug)     config="factory-agents/bug_development.json"; kind="dev" ;;
      story)   config="factory-agents/story_development.json"; kind="dev" ;;
      review)  config="factory-agents/pr_review.json";        kind="review" ;;
      rework)  config="factory-agents/pr_rework.json";        kind="dev" ;;
      *)       config="factory-agents/story_development.json"; kind="dev" ;;
    esac
    echo "run=true" >> "$GITHUB_OUTPUT"
    echo "runner=$runner" >> "$GITHUB_OUTPUT"
    echo "config=$config" >> "$GITHUB_OUTPUT"
    echo "kind=$kind" >> "$GITHUB_OUTPUT"
    echo "→ agent run: $runner (event=$ACTOR, labels=$LABELS, assignees=$ASSIGNEES)"
  else
    echo "run=false" >> "$GITHUB_OUTPUT"
    echo "→ not for the agent (event=$ACTOR, labels=$LABELS, assignees=$ASSIGNEES)"
  fi
