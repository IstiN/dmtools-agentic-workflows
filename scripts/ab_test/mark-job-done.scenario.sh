#!/usr/bin/env bash
# A/B: Mark machine job done (issue task list) — all job.status variants
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init mark-job-done.sh

seed_case() {
  mkdir -p fixtures
  printf '{"body":"## Machine jobs\\n- [ ] \\u25b6 dev (story_development) \\u00b7 [run](https://ci/run/2) \\u00b7 started 10:00 \\u23f3\\n"}\n' > fixtures/body.json
  printf 'issue view	json	%s\n' "${CASE}/fixtures/body.json" > gh_rules.tsv
  printf 'issue edit	out	issue edited\n' >> gh_rules.tsv
  : # no-marker case gets its own rules
  if [ "${AB_CASE_ID}" = no-start-marker ]; then
    printf '{"body":"unrelated body\\n"}\n' > fixtures/body.json
  fi
}

case_env() {
  echo "GH_TOKEN=stub-token"
  echo "NUMBER=42"
  echo "RUN_URL=https://ci/run/2"
  echo "GITHUB_REPOSITORY=IstN/target-repo"
  case "${AB_CASE_ID}" in
    success)   echo "JOB_RESULT=success" ;;
    failure)   echo "JOB_RESULT=failure" ;;
    cancelled) echo "JOB_RESULT=cancelled" ;;
    other)     echo "JOB_RESULT=neutral" ;;
    no-start-marker) echo "JOB_RESULT=success" ;;
  esac
}

ab_case success
ab_case failure
ab_case cancelled
ab_case other
ab_case no-start-marker
ab_done
