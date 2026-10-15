#!/usr/bin/env bash
# A/B: Install prerequisites (fa; no-op on cache hit)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init install-fa-cli.sh

seed_case() {
  mkdir -p fixture-root/setup fixtures
  printf '#!/usr/bin/env bash\necho "setup-install.sh args: $*"\n' > fixture-root/setup/install.sh
  # deterministic fa bundle tarball: bundle/bin/fa + version.txt + lib/x
  local T; T=$(mktemp -d); mkdir -p "$T/bundle/bin" "$T/bundle/lib"
  printf 'fa-binary-stub\n'   > "$T/bundle/bin/fa"
  printf '0.1.418\n'          > "$T/bundle/version.txt"
  printf 'lib-piece\n'        > "$T/bundle/lib/x.so"
  tar -czf fixtures/fa-linux-arm64.tar.gz -C "$T" bundle
  rm -rf "$T"
  : > gh_rules.tsv
  if [ "${AB_CASE_ID}" = latest-assetless-fallback ]; then
    cat > gh_rules.tsv <<RULES
release list	json	${CASE}/fixtures/releases.json
release view v0.1.419	json	${CASE}/fixtures/assets-none.json
release view v0.1.418	json	${CASE}/fixtures/assets-fa.json
release download	file	${CASE}/fixtures/fa-linux-arm64.tar.gz
RULES
    printf '[{"tagName":"v0.1.419"},{"tagName":"v0.1.418"}]\n' > fixtures/releases.json
    printf '{"assets":[]}\n'                                   > fixtures/assets-none.json
    printf '{"assets":[{"name":"fa-linux-arm64.tar.gz"}]}\n'   > fixtures/assets-fa.json
  fi
  case "${AB_CASE_ID}" in
    already-installed)
      mkdir -p home/.local/bin
      printf 'fa-binary-stub\n' > home/.local/bin/fa; chmod +x home/.local/bin/fa
      ;;
  esac
}

case_env() {
  echo "FACTORY_ROOT=${CASE}/fixture-root"
  echo "CURL_FIXTURE_DIR=${CASE}/fixtures"
  case "${AB_CASE_ID}" in
    pinned)                    echo "FA_VERSION=v0.1.418" ;;
    already-installed)
      echo "FA_VERSION=v0.1.418"
      echo "PATH=${CASE}/home/.local/bin:${PATH}" ;;
    latest-assetless-fallback) echo "FA_VERSION=latest" ;;
  esac
}

ab_case pinned
ab_case already-installed
ab_case latest-assetless-fallback
ab_done
