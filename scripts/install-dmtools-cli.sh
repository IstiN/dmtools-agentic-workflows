#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Install dmtools CLI (pinned release bundle)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  if ! curl -fsSL --connect-timeout 15 --max-time 45 --retry 2 --retry-delay 2 \
      "https://github.com/epam/dmtools-dart/releases/download/${DMTOOLS_VERSION}/install.sh" \
      -o /tmp/dmtools-install.sh; then
    echo "browser_download failed; falling back to GitHub Releases API for epam/dmtools-dart@${DMTOOLS_VERSION}/install.sh" >&2
    ASSET_URL="$(gh api "repos/epam/dmtools-dart/releases/tags/${DMTOOLS_VERSION}" --jq '.assets[] | select(.name == "install.sh") | .url')"
    curl -fsSL --connect-timeout 15 --max-time 45 --retry 2 --retry-delay 2 \
      -H "Accept: application/octet-stream" \
      ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
      "${ASSET_URL}" -o /tmp/dmtools-install.sh
  fi
  bash /tmp/dmtools-install.sh "${DMTOOLS_VERSION}"
  echo "$HOME/.dmtools/bin" >> "$GITHUB_PATH"
