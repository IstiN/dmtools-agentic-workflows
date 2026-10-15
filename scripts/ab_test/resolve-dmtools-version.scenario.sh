#!/usr/bin/env bash
# A/B: Resolve dmtools CLI version (latest -> current tag)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init resolve-dmtools-version.sh

seed_case() {
  cat > gh_rules.tsv <<'RULES'
release view	json	${CASE}/fixtures/release.json
RULES
  mkdir -p fixtures
  printf '{"tagName":"v0.1.500"}\n' > fixtures/release.json
}

case_env() {
  echo "GH_TOKEN=stub-token"
  if [ "${AB_CASE_ID}" = latest-resolves ]; then
    echo "DMTOOLS_VERSION=latest"
  else
    echo "DMTOOLS_VERSION=v0.1.499"
  fi
}

ab_case latest-resolves
ab_case pinned-noop
ab_done
