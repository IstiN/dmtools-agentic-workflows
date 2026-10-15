#!/usr/bin/env bash
# A/B: Mark machine job started (issue task list)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init mark-job-started.sh

seed_case() {
  mkdir -p fixtures
  # issue body without a Machine jobs section (first run) and with one (append)
  printf '## Summary\nDo the thing.\n\n## Acceptance\n- works\n' > fixtures/issue_body_fresh.md
  printf '## Summary\nDo the thing.\n\n## Machine jobs\n- [ ] ▶ dev (story_development) · [run](https://ci/run/1) · started 09:59 ⏳\n' > fixtures/issue_body_existing.md
  cat > gh_rules.tsv <<RULES
issue view.*--json body	json-mode-marker
RULES
  # stub cannot switch fixtures by AB_CASE_ID inside tsv — use one file per case
  : > gh_rules.tsv
  if [ "${AB_CASE_ID}" = fresh-section ]; then
    printf 'issue view\tjson\t%s\n' "${CASE}/fixtures/issue_body_fresh.json" > gh_rules.tsv
    printf '{"body":"## Summary\\nDo the thing.\\n\\n## Acceptance\\n- works\\n"}\n' > fixtures/issue_body_fresh.json
  else
    printf 'issue view\tjson\t%s\n' "${CASE}/fixtures/issue_body_existing.json" > gh_rules.tsv
    printf '{"body":"## Summary\\nDo the thing.\\n\\n## Machine jobs\\n- [ ] \\u25b6 dev (story_development) \\u00b7 [run](https://ci/run/1) \\u00b7 started 09:59 \\u23f3\\n"}\n' > fixtures/issue_body_existing.json
  fi
  printf 'issue edit	out	issue edited\n' >> gh_rules.tsv
}

case_env() {
  echo "GH_TOKEN=stub-token"
  echo "NUMBER=42"
  echo "JOB_LEG=dev"
  echo "RUNNER=factory-agents/story_development.json"
  echo "RUN_URL=https://ci/run/2"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
}

ab_case fresh-section
ab_case existing-section
ab_done
