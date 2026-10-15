#!/usr/bin/env bash
# A/B: fa-trace staleness watchdog (backgrounded slice of the Run agent step)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init fa-trace-watchdog.sh

seed_case() {
  mkdir -p seed/.dmtools
  printf 'fa turn output\n' > seed/.dmtools/fa-trace.log
  case "${AB_CASE_ID}" in
    stale-kills)
      touch -t "$(date -u -r "$(( FROZEN_EPOCH - 1800 ))" +%Y%m%d%H%M)" seed/.dmtools/fa-trace.log ;;
    fresh-quiet)
      touch -t "$(date -u -r "$(( FROZEN_EPOCH - 60 ))" +%Y%m%d%H%M)" seed/.dmtools/fa-trace.log ;;
  esac
}

case_env() {
  echo "FA_LOG_FILE=${CASE}/ws/.dmtools/fa-trace.log"
  echo "RUN_OUTPUT=${CASE}/ws/.dmtools/run-output.txt"
  echo "FA_TRACE_STALE_MINUTES=10"
  if [ "${AB_CASE_ID}" = fresh-quiet ]; then
    echo "SLEEP_MAX_CALLS=2"     # bound the 60s poll loop deterministically
  fi
}

extra_capture() {
  echo "── run-output ──"
  cat ws/.dmtools/run-output.txt 2>/dev/null
}

ab_case stale-kills
ab_case fresh-quiet
ab_done
