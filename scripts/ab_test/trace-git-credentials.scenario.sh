#!/usr/bin/env bash
# A/B: Trace git credential stack (push-time evidence)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init trace-git-credentials.sh

seed_case() {
  git -C seed init -q -b main
  git -C seed config user.email t@t; git -C seed config user.name t
  mkdir -p seed/.dmtools
  case "${AB_CASE_ID}" in
    source-helper-wins)
      git -C seed config credential.helper '!f(){ echo username=x-access-token; echo "password=src-secret"; }; f'
      ;;
    extraheader-leftover)
      git -C seed config http.https://github.com/.extraheader 'AUTHORIZATION: basic eC10b2tlbi1zdHVi'
      git -C seed config credential.helper '!f(){ echo username=x-access-token; echo "password=src-secret"; }; f'
      ;;
    submodule-leftover)
      local N="${CASE}/nested"
      git init -q -b main "$N"
      git -C "$N" config user.email t@t; git -C "$N" config user.name t
      printf 'x\n' > "$N/f.txt"; git -C "$N" add .; git -C "$N" -c commit.gpgsign=false commit -qm init
      git -C "$N" config http.https://github.com/.extraheader 'AUTHORIZATION: basic eC10b2tlbi1zdHVi'
      git -C seed -c protocol.file.allow=always submodule add -q "$N" sub >/dev/null 2>&1
      git -C seed config credential.helper '!f(){ echo username=x-access-token; echo "password=src-secret"; }; f'
      ;;
    helper-not-source)
      git -C seed config credential.helper '!f(){ echo username=someone-else; echo "password=other"; }; f'
      ;;
  esac
}

case_env() {
  # user identity for `git var` (frozen author dates come from the lib)
  echo "GIT_AUTHOR_NAME=trace-bot"
  echo "GIT_COMMITTER_NAME=trace-bot"
  echo "GIT_AUTHOR_EMAIL=trace@bot"
  echo "GIT_COMMITTER_EMAIL=trace@bot"
  echo "SOURCE_GITHUB_TOKEN=src-secret"
}

ab_case source-helper-wins
ab_case extraheader-leftover
ab_case submodule-leftover
ab_case helper-not-source
ab_done
