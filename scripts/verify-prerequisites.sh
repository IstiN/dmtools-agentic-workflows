#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Verify prerequisites) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  fa --version
  dmtools --version
  if [ -n "${FLUTTER_VERSION}" ]; then
    flutter --version
    dart --version
  fi
