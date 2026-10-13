#!/usr/bin/env bash
# A/B: Collect fa crash log (uncaught errors live outside the workspace)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init collect-fa-crash-log.sh

seed_case() {
  if [ "${AB_CASE_ID}" = crash-present ]; then
    mkdir -p home/.fah
    printf 'uncaught StreamSink error line 1\nline 2\n' > home/.fah/crash.log
  fi
}

extra_capture() { :; }

case_env() { :; }

ab_case crash-present
ab_case crash-absent
ab_done
