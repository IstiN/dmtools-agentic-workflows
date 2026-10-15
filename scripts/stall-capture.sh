#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Run agent (fa provider via runner env overrides), body slice) — stage-2 de-bloat.
# Behavior contract: identical. Runs BACKGROUND (`... &`) from the run step, like the inline
# `( ... ) &` subshell it replaces; env block stays on the workflow step.
  # Stall-capture sidecar (dmd PR-266 hang investigation 2026-09-28):
  # the Bitrise-pool probe never catches the workload stall because
  # it runs on an IDLE VM; this monitor rides the agent run itself.
  # Every 20s: load, PSI io/mem, all D-state processes, and for every
  # live git/sh/dart process the kernel wait channel (/proc wchan)
  # plus stack and open fds — wchan names WHAT the process sleeps on
  # (disk I/O, network, futex, pipe) which is the proof either way.
  STALL_LOG="${GITHUB_WORKSPACE}/.dmtools/stall-capture.log"
  : > "${STALL_LOG}"
    while sleep 20; do
      {
        echo "=== $(date -u +%H:%M:%S) load=$(cut -d' ' -f1 /proc/loadavg)"
        sed 's/^/psi_io  /' /proc/pressure/io 2>/dev/null
        sed 's/^/psi_mem /' /proc/pressure/memory 2>/dev/null
        ps -eo pid,ppid,state,etime,wchan:32,comm | awk 'NR==1 || $3 ~ /^D/'
        # fa/dmtools comm names do not always match pgrep -x patterns
        # (AOT binary renames, wrapper shells) — match the cmdline.
        for p in $(pgrep -x git 2>/dev/null) $(pgrep -f "bin/fa" 2>/dev/null) $(pgrep -f "dmtools run" 2>/dev/null); do
          echo "--- pid $p ($(cat /proc/$p/comm 2>/dev/null)) state=$(awk '{print $3}' /proc/$p/stat 2>/dev/null) wchan=$(cat /proc/$p/wchan 2>/dev/null)"
          echo "    syscall: $(cat /proc/$p/syscall 2>/dev/null)"
          echo "    cmdline: $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-200)"
          ls -l /proc/$p/fd 2>/dev/null | awk '{print "    fd:", $9, $10, $11}' | head -12
          cat /proc/$p/stack 2>/dev/null | sed 's/^/    stack: /'
        done
      } >> "${STALL_LOG}" 2>&1
    done
