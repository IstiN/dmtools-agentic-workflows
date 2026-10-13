#!/usr/bin/env bash
# A/B: Apply the review verdict (review runs only)
# The verdict PARSER (factory-setup's review-verdict.sh / pack loop/verdict.sh)
# is out of scope here — this exercises THIS step's glue: fallback-source
# assembly, the eval contract, label transitions, escalation comment with the
# GraphQL review-threads query, CI-green gate, and the loud no-verdict path.
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init apply-review-verdict.sh

seed_case() {
  mkdir -p fixtures fixture-root/setup
  cat > fixture-root/setup/review-verdict.sh <<'VSH'
#!/usr/bin/env bash
# verdict-parser stub: emits the eval-safe key=value contract the step consumes
case "${1:-}" in
  decide)
    cat <<EOF
decision=${VSTUB_DECISION:-unknown}
source=stub-source
override=false
blocking_markers=
rounds_done=${VSTUB_ROUNDS:-2}
next_round=${VSTUB_NEXT:-3}
escalate=${VSTUB_ESCALATE:-false}
round_labels=rework-round-2
diagnosis="${VSTUB_DIAGNOSIS:-pr_review.json=missing run-output=missing pr_comments=missing issue_comments=missing}"
EOF
    ;;
  threads)
    printf 'stub thread summary line 1\nstub thread summary line 2\n' ;;
esac
VSH
  chmod +x fixture-root/setup/review-verdict.sh
  printf 'review agent run output line\n' > fixtures/run-output.txt
  printf '{"labels":[{"name":"rework-round-2"},{"name":"needs-human"}]}\n' > fixtures/labels.json
  printf '{"comments":[{"author":{"login":"machine-reviewer[bot]"},"body":"BLOCK marker"},{"author":{"login":"human"},"body":"lgtm"}],"reviews":[{"author":{"login":"machine-reviewer[bot]"},"body":"REQUEST_CHANGES"}]}\n' > fixtures/pr-comments.json
  printf '{"comments":[{"author":{"login":"ai-teammate"},"body":"verdict note"}]}\n' > fixtures/issue-comments.json
  printf '[{"number":7,"body":"closes #42","headRefName":"ai/gh-42"}]\n' > fixtures/pr-list.json
  printf '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}\n' > fixtures/rollup-green.json
  printf '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}\n' > fixtures/rollup-red.json
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"path":"lib/a.dart","line":12,"comments":{"nodes":[{"body":"fix this","author":{"login":"reviewer"}}]}}]}}}}}}\n' > fixtures/threads.json
  printf 'module.exports = { machineAuthor: "machine-reviewer[bot]" };\n' > fixtures/config.js

  local rollup=rollup-green.json prs=pr-list.json
  [ -f seed/.dmtools ] || mkdir -p seed/.dmtools
  case "${AB_CASE_ID}" in
    machine-author-from-config)
      cp fixtures/config.js seed/.dmtools/config.js
      printf '{"decision":"approve"}\n' > /dev/null ;;
    pack-verdict-wins)
      mkdir -p home/.dmtools/packs/pr_review-2.0.0/loop
      printf '#!/usr/bin/env bash\ncase "${1:-}" in decide) echo "decision=${VSTUB_DECISION:-unknown}"; echo "source=pack-loop"; echo "override=false"; echo "rounds_done=1"; echo "next_round=2"; echo "escalate=false"; echo "round_labels="; echo "diagnosis=pack" ;; threads) echo "PACK thread summary" ;; esac\n' \
        > home/.dmtools/packs/pr_review-2.0.0/loop/verdict.sh
      chmod +x home/.dmtools/packs/pr_review-2.0.0/loop/verdict.sh ;;
    approve-red-checks) rollup=rollup-red.json ;;
    no-linked-pr)       prs=pr-list-empty.json ;;
  esac
  cat > gh_rules.tsv <<RULES
issue view.*--json labels.*join	json	${CASE}/fixtures/labels.json
issue view.*--json comments	json	${CASE}/fixtures/issue-comments.json
pr list	json	${CASE}/fixtures/${prs}
pr view.*--json comments,reviews	json	${CASE}/fixtures/pr-comments.json
pr view.*statusCheckRollup	json	${CASE}/fixtures/${rollup}
api graphql	out	${CASE}/fixtures/threads.json
label create	out	label created
issue edit.*--remove-label	out	removed
issue edit.*--add-label	out	added
issue comment.*--body-file	out	comment posted
RULES
}

case_env() {
  echo "NUMBER=42"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
  echo "RUN_OUTPUT=${CASE}/ws/.dmtools/run-output.txt"
  echo "MAX_ROUNDS=2"
  echo "CONFIG=factory-agents/pr_review.json"
  echo "FACTORY_ROOT=${CASE}/fixture-root"
  echo "SLEEP_MAX_CALLS=3"
  mkdir -p "${CASE}/ws/.dmtools" 2>/dev/null
  printf 'review agent run output line\n' > "${CASE}/ws/.dmtools/run-output.txt" 2>/dev/null
  case "${AB_CASE_ID}" in
    no-token) : ;;
    rework-relabel)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=rework" ;;
    rework-escalate)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=rework"; echo "VSTUB_ESCALATE=true" ;;
    approve-green)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=approve" ;;
    approve-red-checks)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=approve" ;;
    approve-no-linked-pr)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=approve" ;;
    no-verdict-loud)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=unknown" ;;
    machine-author-from-config)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=approve" ;;
    pack-verdict-wins)
      echo "GH_TOKEN=stub-token"; echo "VSTUB_DECISION=approve" ;;
  esac
}

extra_capture() { :; }

ab_case no-token
ab_case rework-relabel
ab_case rework-escalate
ab_case approve-green
ab_case approve-red-checks
ab_case approve-no-linked-pr
ab_case no-verdict-loud
ab_case machine-author-from-config
ab_case pack-verdict-wins
ab_done
