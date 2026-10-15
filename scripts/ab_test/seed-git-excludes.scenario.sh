#!/usr/bin/env bash
# A/B: Seed local git excludes (factory workspace artifacts)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init seed-git-excludes.sh

seed_case() {
  git -C seed init -q -b main
}

extra_capture() {
  echo "── .git/info/exclude ──"
  cat ws/.git/info/exclude
}

ab_case excludes-appended
ab_done
