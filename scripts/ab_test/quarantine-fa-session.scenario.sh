#!/usr/bin/env bash
# A/B: Quarantine poisoned fa session
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init quarantine-fa-session.sh

seed_case() {
  git -C seed init -q -b main
  git -C seed config user.email t@t; git -C seed config user.name t
  mkdir -p seed/.dmtools
  # mtimes are seeded relative to the FROZEN clock (exported by the lib)
  stale_trace() { printf 'old trace\n' > seed/.dmtools/fa-trace.log; touch -t "$(date -u -r "$(( FROZEN_EPOCH - 10800 ))" +%Y%m%d%H%M)" seed/.dmtools/fa-trace.log; }
  case "${AB_CASE_ID}" in
    stale-quarantined)
      mkdir -p seed/.dmtools/fa-sessions
      printf 'frozen\n' > seed/.dmtools/fa-sessions/state.json
      stale_trace
      git init -q --bare "${CASE}/origin.git"
      git -C seed remote add origin "${CASE}/origin.git"
      git -C seed commit -q --allow-empty -m root
      git -C seed push -q origin main:refs/heads/fa-sess/GH-9 ;;
    stale-delete-fails)
      stale_trace ;;
    fresh-trace-kept)
      mkdir -p seed/.dmtools/fa-sessions
      printf 'working\n' > seed/.dmtools/fa-sessions/state.json
      printf 'active trace\n' > seed/.dmtools/fa-trace.log
      touch -t "$(date -u -r "$(( FROZEN_EPOCH - 60 ))" +%Y%m%d%H%M)" seed/.dmtools/fa-trace.log ;;
    no-trace)
      mkdir -p seed/.dmtools/fa-sessions
      printf 'x\n' > seed/.dmtools/fa-sessions/state.json ;;
  esac
}

case_env() {
  echo "FA_SESS_BRANCH=fa-sess/GH-9"
  echo "SOURCE_GITHUB_TOKEN=src-secret"
  echo "GITHUB_RUN_ID=9911"
  echo "GITHUB_RUN_ATTEMPT=2"
  echo "AGENT_OUTCOME=cancelled"
}

ab_case stale-quarantined
ab_case stale-delete-fails
ab_case fresh-trace-kept
ab_case no-trace
ab_done
