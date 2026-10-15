#!/usr/bin/env bash
# A/B: Close the rework cycle (rework runs only) — issue-anchored and PR-anchored
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init close-rework-cycle.sh

seed_case() {
  cat > gh_rules.tsv <<'RULES'
pr edit	out	label removed from pr
issue edit	out	label removed from issue
RULES
}

case_env() {
  echo "GH_TOKEN=stub-token"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
  if [ "${AB_CASE_ID}" = pr-anchored ]; then
    echo "PR_NUMBER=7"
  else
    echo "NUMBER=42"
  fi
}

ab_case issue-anchored
ab_case pr-anchored
ab_done
