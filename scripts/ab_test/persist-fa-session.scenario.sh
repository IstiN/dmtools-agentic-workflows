#!/usr/bin/env bash
# A/B: Persist fa session to its git branch
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init persist-fa-session.sh

seed_case() {
  git -C seed init -q -b main
  git -C seed config user.email t@t; git -C seed config user.name t
  printf 'code\n' > seed/app.txt
  git -C seed add . && git -C seed -c commit.gpgsign=false commit -qm init
  git init -q --bare "${CASE}/origin.git"
  git -C seed remote add origin "${CASE}/origin.git"
  git -C seed push -q origin main
  case "${AB_CASE_ID}" in
    session-present)
      mkdir -p seed/.dmtools/fa-sessions/s1
      printf 'turn-1\n' > seed/.dmtools/fa-sessions/s1/state.json ;;
    ignored-only)
      mkdir -p seed/.dmtools/fa-sessions/s1
      printf 'junk\n' > seed/.dmtools/fa-sessions/s1/cache.tmp
      printf '*.tmp\n' > seed/.gitignore
      git -C seed add .gitignore && git -C seed -c commit.gpgsign=false commit -qm gitignore ;;
  esac
}

case_env() {
  echo "FA_SESS_BRANCH=fa-sess/GH-42"
  echo "ANCHOR=gh-42"
  echo "CONFIG=factory-agents/story_development.json"
  echo "SOURCE_GITHUB_TOKEN=src-secret"
}

extra_capture() {
  echo "── origin refs after run ──"
  git -C origin.git for-each-ref --format='%(refname:short) %(objectname:short)' | LC_ALL=C sort
  echo "── sess branch commit ──"
  git -C origin.git log --format='%s' -1 "fa-sess/GH-42" 2>/dev/null
  echo "── sess branch files ──"
  git -C origin.git ls-tree -r --name-only "fa-sess/GH-42" 2>/dev/null | LC_ALL=C sort
}

ab_case session-present
ab_case ignored-only
ab_case no-session
ab_done
