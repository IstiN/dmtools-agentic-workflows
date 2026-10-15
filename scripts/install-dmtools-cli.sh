#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Install dmtools CLI (pinned release bundle)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  curl -fsSL "https://github.com/epam/dmtools-dart/releases/download/${DMTOOLS_VERSION}/install.sh" \
    -o /tmp/dmtools-install.sh
  bash /tmp/dmtools-install.sh "${DMTOOLS_VERSION}"
  echo "$HOME/.dmtools/bin" >> "$GITHUB_PATH"
