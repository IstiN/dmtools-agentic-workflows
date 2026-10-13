#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Install prerequisites (fa; no-op on cache hit)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  if ! command -v fa >/dev/null 2>&1 && [ ! -x "${HOME}/.local/bin/fa" ]; then
    case "$(uname -m)" in
      x86_64) FA_ARCH="x64" ;;
      *)      FA_ARCH="arm64" ;;
    esac
    tmp="$(mktemp -d)"
    # 'latest' is a WORD, not a tag — gh release download takes a
    # literal tag; with no tag it resolves the latest release.
    # (Live failure on IstiN/flutter_agent_harness gh-623: the repo
    # has no FA_VERSION var -> 'latest' -> "release not found".)
    # A fresh latest release can also be asset-less for a while
    # (v0.1.418 2026-09-18: tag landed, binaries never uploaded ->
    # review leg died "no assets to download"). Walk back to the
    # newest release that actually ships the CLI bundle.
    if [ "${FA_VERSION}" = "latest" ] || [ -z "${FA_VERSION}" ]; then
      for t in $(gh release list \
          --repo IstiN/flutter_agent_harness --limit 10 \
          --json tagName --jq '.[].tagName'); do
        if gh release view "$t" --repo IstiN/flutter_agent_harness \
            --json assets --jq '.assets[].name' 2>/dev/null \
            | grep -q "^fa-linux-${FA_ARCH}\.tar\.gz$"; then
          FA_VERSION="$t"
          echo "fa install: latest asset-less, falling back to ${FA_VERSION}"
          break
        fi
      done
    fi
    gh release download "${FA_VERSION}" \
      --repo IstiN/flutter_agent_harness \
      --pattern "fa-linux-${FA_ARCH}.tar.gz" --dir "${tmp}" --clobber
    tar -xzf "${tmp}/fa-linux-${FA_ARCH}.tar.gz" -C "${tmp}"
    mkdir -p "${HOME}/.local/bin" "${HOME}/.local/lib"
    cp "${tmp}/bundle/bin/fa" "${HOME}/.local/bin/fa"
    chmod +x "${HOME}/.local/bin/fa"
    # version.txt next to the binary — _packageVersion probes
    # <exe_dir>/version.txt; without it the CLI reports the 0.1.0
    # fallback and every session reinstalls (2026-10-01 loop).
    [ -f "${tmp}/bundle/version.txt" ] \
      && cp "${tmp}/bundle/version.txt" "${HOME}/.local/bin/version.txt"
    cp -R "${tmp}/bundle/lib/." "${HOME}/.local/lib/" 2>/dev/null || true
  fi
  bash "${FACTORY_ROOT}/setup/install.sh" "fa:${FA_VERSION}"
