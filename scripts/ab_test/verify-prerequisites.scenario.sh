#!/usr/bin/env bash
# A/B: Verify prerequisites (fa/dmtools version probes, flutter when pinned)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init verify-prerequisites.sh

seed_case() {
  mkdir -p bin
  for tool in fa dmtools flutter dart; do
    printf '#!/usr/bin/env bash\necho "%s 9.9.9-stub"\n' "${tool}" > "bin/${tool}"
    chmod +x "bin/${tool}"
  done
}

case_env() {
  echo "PATH=${CASE}/bin:${PATH}"
  if [ "${AB_CASE_ID}" = with-flutter ]; then
    echo "FLUTTER_VERSION=3.24.0"
  else
    echo "FLUTTER_VERSION="
  fi
}

ab_case with-flutter
ab_case no-flutter
ab_done
