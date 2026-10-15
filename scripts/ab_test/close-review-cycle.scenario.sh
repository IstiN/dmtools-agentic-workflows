#!/usr/bin/env bash
# A/B: Close the review cycle (review runs only)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init close-review-cycle.sh

seed_case() {
  cat > gh_rules.tsv <<'RULES'
remove-label	out	label removed
RULES
}

case_env() {
  echo "NUMBER=42"
  echo "GH_TOKEN=stub-token"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
}

ab_case label-stripped
ab_done
