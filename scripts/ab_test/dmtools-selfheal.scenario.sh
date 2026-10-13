#!/usr/bin/env bash
# A/B: dmtools self-heal probe (sourced slice of the Run agent step)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init dmtools-selfheal.sh

seed_case() {
  mkdir -p bin fixtures fixture-root "${CASE}/home/.dmtools/bin" 2>/dev/null || { mkdir -p bin fixtures fixture-root; mkdir -p home/.dmtools/bin; }
  # fixed dmtools on the step PATH that FAILS the probe (broken install)
  printf '#!/usr/bin/env bash\necho "dmtools: cannot open file" >&2\nexit 1\n' > bin/dmtools
  chmod +x bin/dmtools
  # the reinstalled bundle in $HOME/.dmtools/bin — healthy
  printf '#!/usr/bin/env bash\necho "dmtools 0.1.500 (healed stub)"\n' > home/.dmtools/bin/dmtools
  chmod +x home/.dmtools/bin/dmtools
  # curl-served installer
  printf '#!/usr/bin/env bash\necho "dmtools-heal installer args: $*"\n' > fixtures/install.sh
  case "${AB_CASE_ID}" in
    healthy-no-heal)
      printf '#!/usr/bin/env bash\necho "dmtools 0.1.500 (healthy stub)"\n' > bin/dmtools
      chmod +x bin/dmtools ;;
  esac
}

case_env() {
  echo "DMTOOLS_VERSION=v0.1.500"
  echo "PATH=${CASE}/bin:${PATH}"
  echo "CURL_FIXTURE_DIR=${CASE}/fixtures"
}

ab_case broken-heals
ab_case healthy-no-heal
ab_done
