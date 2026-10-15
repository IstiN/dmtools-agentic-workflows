#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Fetch factory-setup (dmtools-agents releases — no tree checkout)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  set -eu
  # Compat branch: mounted tree wins, untouched.
  if [ -d "${GITHUB_WORKSPACE}/factory-agents" ]; then
    echo "→ compat: factory-agents/ tree is mounted — it wins (FACTORY_ROOT=tree)"
    echo "FACTORY_ROOT=${GITHUB_WORKSPACE}/factory-agents" >> "$GITHUB_ENV"
    exit 0
  fi
  # awf#25 pin parity: a pinned fleet must never float to newest
  # pack content through a floating registry base. AGENTS_KNOB
  # (concrete tag) wins; 'latest'/unset keeps the historical
  # PACK_TAG resolution below.
  if [ -n "${AGENTS_KNOB}" ] && [ "${AGENTS_KNOB}" != "latest" ]; then
    tag="${AGENTS_KNOB}"
  else
    tag="${PACK_TAG}"
  fi
  # DMTOOLS_PACK_REGISTRY is the dm.ai #579 RESOLVER format — a
  # releases BASE URL (…/releases/latest/download) or a tag URL;
  # only a bare tag can feed `gh release download` directly.
  case "${tag}" in
    http*)
      # …/releases/tag/<tag> pins exactly; anything else (/latest/,
      # /download/) resolves to the newest agents-rel-* tag.
      pinned="$(printf '%s' "${tag}" | sed -n 's#.*/releases/tag/\([A-Za-z0-9._-]\+\).*#\1#p')"
      if [ -n "${pinned}" ] && printf '%s' "${pinned}" | grep -q '^agents-rel-'; then
        tag="${pinned}"
      else
        tag=""
      fi
      ;;
  esac
  if [ -z "${tag}" ]; then
    tag="$(gh release list --repo IstiN/dmtools-agents --limit 10 --json tagName \
      --jq '[.[].tagName | select(startswith("agents-rel-"))] | .[0]')"
    [ -n "${tag}" ] || { echo "::error::no agents-rel-* release found in IstiN/dmtools-agents"; exit 1; }
    echo "::notice::factory-setup from newest release ${tag}"
  fi
  dir="${RUNNER_TEMP}/factory-setup"
  mkdir -p "${dir}"
  tmp="$(mktemp -d)"
  gh release download "${tag}" --repo IstiN/dmtools-agents \
    --pattern 'factory-setup-*.zip' --dir "${tmp}" --clobber
  unzip -q "${tmp}"/factory-setup-*.zip -d "${dir}"
  [ -f "${dir}/setup/cache.sh" ] || { echo "::error::factory-setup incomplete at ${tag} (no setup/cache.sh)"; exit 1; }
  [ -f "${dir}/configs/pr_review.json" ] || { echo "::error::factory-setup incomplete at ${tag} (no configs/)"; exit 1; }
  echo "→ factory-setup from ${tag} (FACTORY_ROOT=${dir})"
  echo "FACTORY_ROOT=${dir}" >> "$GITHUB_ENV"
  # awf#25: the resolved tag feeds the runtime pack registry (see
  # the agent-run step) — setup content and pack content pin
  # together from this point on.
  echo "RESOLVED_AGENTS_TAG=${tag}" >> "$GITHUB_ENV"
