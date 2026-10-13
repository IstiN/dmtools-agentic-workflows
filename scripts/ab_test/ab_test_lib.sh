#!/usr/bin/env bash
# A/B harness core: run one workflow step's OLD inline body (byte-rendered from
# the pre-de-bloat snapshot) and its NEW extracted script against identical
# sandboxed fixtures, then diff stdout / stderr / exit code / $GITHUB_ENV /
# $GITHUB_OUTPUT / recorded gh calls / workspace file tree / extra capture —
# byte-for-byte.
#
# Scenario contract (scripts/ab_test/<name>.scenario.sh):
#   source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
#   ab_init <script-name>              # renders the old body, checks the new script
#   seed_case() { ... }                # populate $CASE/seed (workspace) + fixtures;
#                                      # runs INSIDE $CASE (fresh per mode) — must
#                                      # produce identical state for both modes
#   case_env() { ... }                 # emit KEY=VALUE lines (run env, incl.
#                                      # GITHUB_* fixture paths already set)
#   extra_capture() { ... }            # optional: stdout text compared across modes
#   ab_case <case-id> [more cases...]  # run + compare; AB_FAIL counter
#   ab_done                            # summary + exit code
#
# Both modes run from the SAME absolute paths ($CASE/ws, $CASE/gh_env, ...) —
# scripts echo $RUNNER_TEMP / $GITHUB_WORKSPACE into logs, so path identity is
# load-bearing. The sandbox is re-seeded between the two runs.

export AB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "${AB_ROOT}/../.." && pwd)"
export OLD_SNAPSHOT="a4cd62f"   # last pre-de-bloat factory-teammate.yml
export STUBS="${AB_ROOT}/stubs"

AB_FAIL=0
AB_PASS=0
CURRENT_SCRIPT=""

_ab_w() { printf '%s\n' "$*" >>"${AB_LOG:-/dev/null}"; }

die() { printf 'FATAL(ab): %s\n' "$*" >&2; exit 2; }

# ab_init <script-name>
ab_init() {
  CURRENT_SCRIPT="$1"
  [ -f "${REPO_ROOT}/scripts/${CURRENT_SCRIPT}" ] || die "no scripts/${CURRENT_SCRIPT}"
  AB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ab_${CURRENT_SCRIPT%.sh}.XXXXXX")"
  export AB_TMP
  rm -rf "${TMPDIR:-/tmp}"/ab_* 2>/dev/null   # keep only the live run's sandbox
  AB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ab_${CURRENT_SCRIPT%.sh}.XXXXXX")"
  export AB_TMP
  # OLD body: snapshot -> manifest slice -> documented ${{ }} rewrites.
  python3 "${AB_ROOT}/render_old_body.py" old "${CURRENT_SCRIPT}" "${AB_TMP}/old_body.sh" \
    || die "render_old_body failed for ${CURRENT_SCRIPT}"
  printf '== A/B %s ==\n' "${CURRENT_SCRIPT}"
}

# ab_case <case-id>
ab_case() {
  local cid="$1" mode
  export AB_CASE_ID="${cid}"
  for mode in old new; do
    # fresh identical sandbox at IDENTICAL absolute paths for both modes
    rm -rf "${AB_TMP}/case"
    mkdir -p "${AB_TMP}/case"/{seed,ws,out,bin,home}
    CASE="${AB_TMP}/case"
    export FROZEN_EPOCH="${FROZEN_EPOCH:-1791885600}"   # 2026-10-13T10:00:00Z
    export GIT_CONFIG_GLOBAL="${CASE}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_DATE="2026-10-13T10:00:00+0000" GIT_COMMITTER_DATE="2026-10-13T10:00:00+0000"
    : > "${CASE}/gitconfig"   # scenario may append fixed git identity in seed_case
    (
      cd "${CASE}" || exit 99
      seed_case            # scenario fixture setup; may create seed/, fixtures/
      cp -a seed/. ws/ 2>/dev/null
    ) || die "seed_case failed (${CURRENT_SCRIPT}/${cid}/${mode})"
    : > "${CASE}/out/stdout" ; : > "${CASE}/out/stderr"
    : > "${CASE}/gh_env" ; : > "${CASE}/gh_output" ; : > "${CASE}/gh_calls.log"
    : > "${CASE}/gh_path"
    : > "${CASE}/pkill.log" ; : > "${CASE}/curl.log" ; : > "${CASE}/sleep.log"
    : > "${CASE}/date.log"
    local script_path
    if [ "${mode}" = old ]; then script_path="${AB_TMP}/old_body.sh"
    else script_path="${REPO_ROOT}/scripts/${CURRENT_SCRIPT}"; fi
    (
      cd "${CASE}/ws" || exit 99
      export HOME="${CASE}/home"
      export RUNNER_TEMP="${CASE}/runner-temp" GITHUB_WORKSPACE="${CASE}/ws"
      export GITHUB_ENV="${CASE}/gh_env" GITHUB_OUTPUT="${CASE}/gh_output"
      export GITHUB_PATH="${CASE}/gh_path"
      export GH_CALL_LOG="${CASE}/gh_calls.log" PKILL_LOG="${CASE}/pkill.log"
      export CURL_LOG="${CASE}/curl.log" SLEEP_LOG="${CASE}/sleep.log"
      export DATE_LOG="${CASE}/date.log"
      export SLEEP_COUNTER="${CASE}/sleep.count"
      export GH_STUB_RULES="${CASE}/gh_rules.tsv"
      export PATH="${STUBS}:${PATH}"
      export FROZEN_EPOCH="${FROZEN_EPOCH:-1791885600}"   # 2026-10-13T10:00:00Z
      # scenario-supplied env (evaluated, not sourced into this shell's state)
      while IFS= read -r kv; do
        [ -n "${kv}" ] && export "${kv?}"
      done < <(case_env 2>/dev/null)
      # scratch dirs scripts expect
      mkdir -p "${RUNNER_TEMP}/factory-kit/kit" "${RUNNER_TEMP}/factory-setup"
      mkdir -p "${AB_TMP}/run"
      if [ "${mode}" = old ]; then cp "${AB_TMP}/old_body.sh" "${AB_TMP}/run/body.sh"
      else cp "${REPO_ROOT}/scripts/${CURRENT_SCRIPT}" "${AB_TMP}/run/body.sh"; fi
      bash -e "${AB_TMP}/run/body.sh" >"${CASE}/out/stdout" 2>"${CASE}/out/stderr"
      echo "$?" > "${CASE}/out/rc"
      exit 0
    )
    # normalize the two systematic old-vs-new differences:
    #  - the 5-line provenance header shifts bash error line numbers by 5
    #  - mktemp dir basenames created INSIDE the script under $TMPDIR
    for f in "${CASE}/out/stdout" "${CASE}/out/stderr" "${CASE}/gh_calls.log" \
             "${CASE}/pkill.log" "${CASE}/curl.log" "${CASE}/date.log" "${CASE}/sleep.log"; do
      [ -f "$f" ] || continue
      if [ "${mode}" = new ]; then
        perl -pi -e 's{/run/body\.sh: line (\d+):}{ "/run/body.sh: line " . ($1 - 5) . ":" }ge' "$f"
      fi
      perl -pi -e 's{tmp\.[A-Za-z0-9]{6,15}}{tmp.XXXXXXXXXX}g' "$f"
    done
    # artifacts snapshot (identical layout both modes)
    {
      echo "rc: $(cat "${CASE}/out/rc" 2>/dev/null || echo KILLED)"
      echo "--- stdout:"; cat "${CASE}/out/stdout"
      echo "--- stderr:"; cat "${CASE}/out/stderr"
      echo "--- gh_env:";   cat "${CASE}/gh_env"
      echo "--- gh_output:"; cat "${CASE}/gh_output"
      echo "--- gh_path:";  cat "${CASE}/gh_path"
      echo "--- gh_calls:"; cat "${CASE}/gh_calls.log"
      echo "--- pkill:";    cat "${CASE}/pkill.log"
      echo "--- curl:";     cat "${CASE}/curl.log"
      echo "--- date:";     cat "${CASE}/date.log"
      echo "--- tree:"
      for root in ws home runner-temp; do
        echo "  [${root}]"
        ( cd "${CASE}/${root}" 2>/dev/null && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort \
            | while IFS= read -r f; do printf '  %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done )
      done
      echo "--- extra:"
      if [ "$(declare -F extra_capture)" != "" ]; then
        ( cd "${CASE}" && extra_capture 2>/dev/null )
      fi
    } > "${AB_TMP}/artifact_${CURRENT_SCRIPT%.sh}_${cid}_${mode}.txt"
  done
  local f1="${AB_TMP}/artifact_${CURRENT_SCRIPT%.sh}_${cid}_old.txt"
  local f2="${AB_TMP}/artifact_${CURRENT_SCRIPT%.sh}_${cid}_new.txt"
  if diff -u "$f1" "$f2" >"${AB_TMP}/diff_${cid}.txt" 2>&1; then
    printf '  PASS  %-28s (%s)\n' "${cid}" "${CURRENT_SCRIPT}"
    AB_PASS=$((AB_PASS+1))
    rm -rf "${AB_TMP}/case"
  else
    printf '  FAIL  %-28s (%s)\n' "${cid}" "${CURRENT_SCRIPT}"
    sed -n '1,40p' "${AB_TMP}/diff_${cid}.txt"
    AB_FAIL=$((AB_FAIL+1))
  fi
}

ab_done() {
  printf '== %s: %d pass, %d fail ==\n' "${CURRENT_SCRIPT}" "${AB_PASS}" "${AB_FAIL}"
  [ "${AB_FAIL}" -eq 0 ] || exit 1
  exit 0
}
