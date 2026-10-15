#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Run agent (fa provider via runner env overrides), body slice) — stage-2 de-bloat.
# Behavior contract: identical. Invoke SOURCED (`. script`) from the run step: the dmtools
# self-heal must export the repaired PATH back into the step shell.
  # ── dmtools self-heal (self-hosted runners keep a persistent $HOME) ──
  # A stale or half-updated ~/.dmtools/bin from an older install
  # layout kills the leg instantly with "Error: Cannot open file"
  # (live: epam/dmtools-dart pr-301 review, run 36614989141 — the
  # install step's own `dmtools --version` printed 0.1.22, and the
  # run step 14s later died before any output). Probe what PATH
  # actually resolves at RUN time, verify it, and force-reinstall
  # the pinned bundle when the resolution is broken.
  echo "── dmtools self-check ──"
  echo "resolved: $(command -v dmtools || echo MISSING)"
  ls -la "${HOME}/.dmtools/bin" 2>/dev/null | head -8 || true
  if ! dmtools --version >/dev/null 2>&1; then
    echo "dmtools on PATH is broken — force reinstall (${DMTOOLS_VERSION})"
    curl -fsSL "https://github.com/epam/dmtools-dart/releases/download/${DMTOOLS_VERSION}/install.sh" \
      -o /tmp/dmtools-heal.sh
    bash /tmp/dmtools-heal.sh "${DMTOOLS_VERSION}"
    export PATH="${HOME}/.dmtools/bin:${PATH}"
    hash -r
  fi
  echo "resolved after heal: $(command -v dmtools || echo MISSING)"
  dmtools --version
