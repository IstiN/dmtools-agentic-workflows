#!/usr/bin/env bash
# A/B: Restore fa session (resume the ticket conversation)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init restore-fa-session.sh

seed_case() {
  git -C seed init -q -b main
  git -C seed config user.email t@t; git -C seed config user.name t
  if [ "${AB_CASE_ID}" = branch-exists ]; then
    git -C seed remote add origin "${CASE}/origin.git"
    git init -q --bare "${CASE}/origin.git"
    mkdir -p seed/.dmtools/fa-sessions
    printf 'sess-data-v1\n' > seed/.dmtools/fa-sessions/store.txt
    git -C seed add .dmtools && git -C seed -c commit.gpgsign=false commit -qm sess
    git -C seed push -q origin main:refs/heads/fa-sess/GH-5
    git -C seed rm -rq .dmtools && git -C seed -c commit.gpgsign=false commit -qm clean
  fi
}

case_env() {
  echo "FA_SESS_BRANCH=fa-sess/GH-5"
}

ab_case branch-exists
ab_case branch-absent
ab_done
