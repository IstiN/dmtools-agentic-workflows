#!/usr/bin/env bash
# A/B: Write the issue into the agent input folder
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init write-input-issue.sh

seed_case() {
  mkdir -p fixtures
  cat > gh_rules.tsv <<RULES
issue view.*--json number,json	total-different-fields
RULES
  # two distinct issue-view calls: the tracker-contract json and the md fields
  cat > gh_rules.tsv <<RULES
--json number,title,body,url,state,labels	json	${CASE}/fixtures/issue-full.json
--json title,body	json	${CASE}/fixtures/issue-md.json
RULES
  printf '{"number":42,"title":"[bug] save crashes","body":"body line 1\\nbody line 2","url":"https://github/IstN/target-repo/issues/42","state":"OPEN","labels":[{"name":"bug"},{"name":"agent:dev"}]}\n' > fixtures/issue-full.json
  printf '{"title":"[bug] save crashes","body":"body line 1\\nbody line 2"}\n' > fixtures/issue-md.json
}

case_env() {
  echo "GH_TOKEN=stub-token"
  echo "NUMBER=42"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
}

ab_case ticket-files-written
ab_done
