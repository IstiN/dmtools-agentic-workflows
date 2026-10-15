#!/usr/bin/env bash
# A/B: Publish leg token usage (fa-tokens ledger -> factory-data branch)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init publish-token-usage.sh

seed_case() {
  mkdir -p fixtures ws/.dmtools
  # run output with two fa-tokens segments (resume-aware: both summed),
  # junk around them, one malformed line (skipped), one with a model field
  cat > ws/.dmtools/run-output.txt <<'OUT'
::log:: agent starting
fa-tokens: {"input":1200,"output":340,"cacheRead":55}
some wrapper {"not":"a ledger"} line
fa-tokens:	{"input":800,"output":160,"cacheRead":11,"model":"claude-sonnet-4"}
fa-tokens: {"input": broken json
done.
OUT
  : > ws/.dmtools/run-output-empty.txt
  printf 'no ledger markers here\nplain text only\n' > ws/.dmtools/run-output-noledger.txt
  printf 'fa-tokens: {"input":0,"output":0,"cacheRead":0}\n' > ws/.dmtools/run-output-zero.txt
  # existing factory-data state: one current row + one stale row (cutoff prune)
  printf '{"issue-42":[{"leg":"dev","at":"2020-01-01T00:00:00Z","prompt":1,"completion":1,"total":2,"cacheRead":0,"model":"old"},{"leg":"dev","at":"2026-10-13T00:00:00Z","prompt":10,"completion":20,"total":30,"cacheRead":1,"model":"m"}],"pr-7":[{"leg":"review","at":"2026-10-13T00:00:00Z","prompt":5,"completion":6,"total":11,"cacheRead":0,"model":"m"}]}' \
    > fixtures/data.json
  B64="$(base64 < fixtures/data.json | tr -d '\n')"
  printf '{"name":"tokens.json","path":"factory-data/tokens.json","sha":"deadbeefsha","content":"%s","encoding":"base64"}\n' "${B64}" > fixtures/contents-meta.json
  printf '{"default_branch":"main"}\n' > fixtures/default-branch.json
  printf '{"object":{"sha":"baseshasha"}}\n' > fixtures/git-ref.json
  printf '{"ref":"refs/heads/factory-data","sha":"baseshasha"}\n' > fixtures/new-ref.json

  local ro=run-output.txt anchor=gh-42 config=bug_development.json kind=dev put=fail0
  case "${AB_CASE_ID}" in
    empty-run-output)    ro=run-output-empty.txt ;;
    no-ledger-lines)     ro=run-output-noledger.txt ;;
    zero-tokens)         ro=run-output-zero.txt ;;
    pr-anchor)           anchor=pr-7 ;;
    rework-slot)         config=pr_rework.json ;;
    bad-anchor)          anchor=weird-9 ;;
    publish-conflict-retry) put=fail1 ;;
    publish-gave-up)     put=fail99 ;;
  esac
  cat > gh_rules.tsv <<RULES
api repos/IstN/target-repo --jq .default_branch	json	${CASE}/fixtures/default-branch.json
git/ref/heads	json	${CASE}/fixtures/git-ref.json
-X POST.*git/refs	out	${CASE}/fixtures/new-ref.json
contents/factory-data/tokens.json\?ref=	json	${CASE}/fixtures/contents-meta.json
-X PUT.*contents/factory-data/tokens.json	${put:+@@FAIL_UNTIL:${put}@@}out	ok
RULES
  # the case-selected run output is what RUN_OUTPUT points at
  cp "ws/.dmtools/${ro}" "ws/.dmtools/run-output.active.txt"
}

case_env() {
  echo "REPO=IstN/target-repo"
  echo "DATA_BRANCH=factory-data"
  echo "DATA_PATH=factory-data/tokens.json"
  echo "ANCHOR=$( [ "${AB_CASE_ID}" = pr-anchor ] && echo pr-7 || { [ "${AB_CASE_ID}" = bad-anchor ] && echo weird-9 || echo gh-42; } )"
  echo "KIND=dev"
  case "${AB_CASE_ID}" in
    rework-slot) echo "CONFIG=factory-agents/pr_rework.json" ;;
    *)           echo "CONFIG=factory-agents/bug_development.json" ;;
  esac
  echo "RUN_OUTPUT=${CASE}/ws/.dmtools/run-output.active.txt"
  echo "SLEEP_MAX_CALLS=4"
}

extra_capture() { :; }

ab_case publish-issue-anchor
ab_case pr-anchor
ab_case rework-slot
ab_case bad-anchor
ab_case empty-run-output
ab_case no-ledger-lines
ab_case zero-tokens
ab_case publish-conflict-retry
ab_case publish-gave-up
ab_done
