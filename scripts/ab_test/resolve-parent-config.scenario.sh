#!/usr/bin/env bash
# A/B: Resolve parent config (pack launch.json wins, tree fallback)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init resolve-parent-config.sh

seed_case() {
  case "${AB_CASE_ID}" in
    pack-wins)
      mkdir -p home/.dmtools/packs/pr_review-1.2.0 home/.dmtools/packs/pr_review-1.10.0
      printf '{"launch":"v1.2.0"}\n' > home/.dmtools/packs/pr_review-1.2.0/launch.json
      printf '{"launch":"v1.10.0"}\n' > home/.dmtools/packs/pr_review-1.10.0/launch.json
      ;;
    legacy-root)
      mkdir -p fixture-root
      printf '{"launch":"tree"}\n' > fixture-root/pr_review.json
      ;;
    legacy-configs)
      mkdir -p fixture-root/configs
      printf '{"launch":"zip-configs"}\n' > fixture-root/configs/pr_review.json
      ;;
    missing) : ;;
  esac
}

case_env() {
  echo "LEGACY_CONFIG=factory-agents/pr_review.json"
  echo "FACTORY_ROOT=${CASE}/fixture-root"
}

ab_case pack-wins
ab_case legacy-root
ab_case legacy-configs
ab_case missing
ab_done
