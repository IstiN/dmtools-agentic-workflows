#!/usr/bin/env bash
# A/B: stall-capture sidecar (backgrounded slice of the Run agent step)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init stall-capture.sh

seed_case() {
  # scenario-local stubs: deterministic /proc, ps, pgrep (macOS has no /proc)
  mkdir -p local-stubs fixtures/proc/401 fixtures/proc/402 fixtures/proc/501 fixtures/proc/601
  cat > local-stubs/cat <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  /proc/*) f="${STALL_FIXTURES}${1}"; [ -f "$f" ] && { /bin/cat "$@"; exit 0; }; exit 1 ;;
  *) exec /bin/cat "$@" ;;
esac
STUB
  cat > local-stubs/ps <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '  PID  PPID STAT     ETIME WCHAN                       COMMAND'
printf '%s\n' '  401     1 D        02:11 do_exit                         git'
printf '%s\n' '  501   400 S        01:00 poll_wait                        fa'
STUB
  cat > local-stubs/pgrep <<'STUB'
#!/usr/bin/env bash
case "${@}" in
  *"-x git"*) printf '401\n402\n' ;;
  *"bin/fa"*) printf '501\n' ;;
  *"dmtools run"*) printf '601\n' ;;
  *) : ;;
esac
STUB
  chmod +x local-stubs/*
  for p in 401 402 501 601; do
    printf 'git\n'      > "fixtures/proc/$p/comm"
    printf '1 (git) D 2 0 0 0 -1 0 0 0 0 0 0 0 0 0 0 0 0\n' > "fixtures/proc/$p/stat"
    printf '0\n'        > "fixtures/proc/$p/syscall"
    printf 'git\x00status\x00' > "fixtures/proc/$p/cmdline"
    printf 'stack-frame-0\nstack-frame-1\n' > "fixtures/proc/$p/stack"
  done
}

case_env() {
  echo "STALL_LOG=${CASE}/ws/.dmtools/stall-capture.log"
  echo "SLEEP_MAX_CALLS=2"
  echo "PATH=${CASE}/local-stubs:${PATH}"
  echo "STALL_FIXTURES=${CASE}/fixtures"
}

extra_capture() {
  echo "── stall log ──"
  cat ws/.dmtools/stall-capture.log 2>/dev/null
}

ab_case two-iterations
ab_done
