#!/usr/bin/env bash
# A/B: Install dmtools CLI (pinned release bundle)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init install-dmtools-cli.sh

seed_case() {
  mkdir -p fixtures
  printf '#!/usr/bin/env bash\necho "dmtools-installer args: $*"\n' > fixtures/install.sh
}

case_env() {
  echo "DMTOOLS_VERSION=v0.1.500"
  echo "CURL_FIXTURE_DIR=${CASE}/fixtures"
}

ab_case installer-runs
ab_done
