#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Resolve parent config (pack launch.json wins, tree fallback)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  set -eu
  agent="$(basename "${LEGACY_CONFIG}" .json)"
  pack_launch="$(ls -1 "${HOME}"/.dmtools/packs/"${agent}"-*/launch.json 2>/dev/null | sort -V | tail -1 || true)"
  if [ -n "${pack_launch}" ]; then
    echo "→ pack launch.json wins: ${pack_launch}"
    echo "AI_TEAMMATE_CONFIG_FILE=${pack_launch}" >> "$GITHUB_ENV"
    exit 0
  fi
  # No unpacked pack — the legacy fallback now lives under
  # FACTORY_ROOT: a mounted tree keeps its root-level <agent>.json
  # layout; the factory-setup zip ships configs/<agent>.json.
  for legacy_path in \
    "${FACTORY_ROOT}/${agent}.json" \
    "${FACTORY_ROOT}/configs/${agent}.json"; do
    if [ -f "${legacy_path}" ]; then
      echo "→ no unpacked ${agent} pack launch.json — legacy config: ${legacy_path}"
      echo "AI_TEAMMATE_CONFIG_FILE=${legacy_path}" >> "$GITHUB_ENV"
      exit 0
    fi
  done
  echo "::error::no parent config for '${agent}': neither ~/.dmtools/packs/${agent}-*/launch.json nor ${FACTORY_ROOT}/${agent}.json nor ${FACTORY_ROOT}/configs/${agent}.json exists — no Wave-2 pack unpacked and the factory-setup legacy configs are missing"
  exit 1
