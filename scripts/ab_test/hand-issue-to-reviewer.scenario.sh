#!/usr/bin/env bash
# A/B: Hand the issue to the reviewer (dev runs only)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init hand-issue-to-reviewer.sh

seed_case() {
  cat > gh_rules.tsv <<'RULES'
issue edit	out	label edit ok
RULES
}

case_env() {
  echo "NUMBER=42"
  echo "GH_TOKEN=stub-token"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
}

ab_case review-handoff-labels
ab_done
