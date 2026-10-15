#!/usr/bin/env bash
# A/B: Persist fa project memory into the repository
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init persist-fa-memory.sh

seed_case() {
  git -C seed init -q -b main
  git -C seed config user.email t@t; git -C seed config user.name t
  printf 'readme\n' > seed/README.md
  git -C seed add . && git -C seed -c commit.gpgsign=false commit -qm init
  git init -q --bare "${CASE}/origin.git"
  git -C seed remote add origin "${CASE}/origin.git"
  git -C seed push -q origin main
  # factory-kit credential installer stub (the step prefers the kit copy)
  mkdir -p "${CASE}/kit-parent/factory-kit/kit" "${CASE}/fixture-root/setup"
  printf '#!/usr/bin/env bash\necho "kit credential installer: $*"\n' \
    > "${CASE}/kit-parent/factory-kit/kit/install-source-git-credentials.sh"
  printf '#!/usr/bin/env bash\necho "fallback credential installer: $*"\n' \
    > "${CASE}/fixture-root/setup/install-source-git-credentials.sh"
  case "${AB_CASE_ID}" in
    memory-changed)
      mkdir -p seed/.fah/memory
      printf 'learned: run tests first\n' > seed/.fah/memory/notes.md ;;
    kit-installer-missing)
      rm -f "${CASE}/kit-parent/factory-kit/kit/install-source-git-credentials.sh"
      mkdir -p seed/.fah/memory
      printf 'learned: fallback path\n' > seed/.fah/memory/notes.md ;;
    extraheader-leftover)
      git -C seed config http.https://github.com/.extraheader 'AUTHORIZATION: basic eC10b2tlbi1zdHVi' ;;
  esac
}

case_env() {
  echo "GH_TOKEN=stub-token"
  echo "SOURCE_GITHUB_TOKEN=src-secret"
  echo "RUNNER_TEMP=${CASE}/kit-parent"
  echo "FACTORY_ROOT=${CASE}/fixture-root"
}

extra_capture() {
  echo "── origin refs after run ──"
  git -C origin.git for-each-ref --format='%(refname:short) %(objectname:short)' | LC_ALL=C sort
  echo "── HEAD subject ──"
  git -C ws log --format='%s' -1 2>/dev/null
}

ab_case memory-changed
ab_case kit-installer-missing
ab_case nothing-to-persist
ab_case extraheader-leftover
ab_done
