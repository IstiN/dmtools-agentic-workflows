#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Resolve dmtools CLI version (latest -> current tag)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  if [ "${DMTOOLS_VERSION:-}" = "latest" ]; then
    TAG="$(gh release view --repo epam/dmtools-dart --json tagName --jq .tagName)"
    echo "DMTOOLS_VERSION=${TAG}" >> "$GITHUB_ENV"
    echo "::notice::dmtools CLI: latest resolved to ${TAG}"
  fi
