#!/usr/bin/env bash
# A/B: Write the PR into the agent input folder (PR-anchored runs)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init write-input-pr.sh

seed_case() {
  mkdir -p fixtures
  cat > gh_rules.tsv <<RULES
--json number,title,body,url,state,labels	json	${CASE}/fixtures/pr-full.json
--json title,body	json	${CASE}/fixtures/pr-md.json
RULES
  printf '{"number":7,"title":"Fix save","body":"closes #42","url":"https://github/IstN/target-repo/pull/7","state":"OPEN","labels":[{"name":"agent:rework"}]}\n' > fixtures/pr-full.json
  printf '{"title":"Fix save","body":"closes #42"}\n' > fixtures/pr-md.json
}

case_env() {
  echo "GH_TOKEN=stub-token"
  echo "PR_NUMBER=7"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
}

ab_case pr-ticket-files-written
ab_done
