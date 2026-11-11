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
    dev-mode-field)
      # gh-92: a leg config carrying the developmentMode knob (new customParams
      # field) must select identically — path-only hand-off, content untouched.
      mkdir -p home/.dmtools/packs/ai_teammate-9.9.9
      printf '{"params":{"customParams":{"developmentMode":"plan","developmentModeConfig":{"adaptive":{"planIfBodyTokensAtLeast":800}}}}}\n' \
        > home/.dmtools/packs/ai_teammate-9.9.9/launch.json
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
  if [ "${AB_CASE_ID:-}" = "dev-mode-field" ]; then
    echo "LEGACY_CONFIG=ai_teammate"
  else
    echo "LEGACY_CONFIG=factory-agents/pr_review.json"
  fi
  echo "FACTORY_ROOT=${CASE}/fixture-root"
}

ab_case pack-wins
ab_case dev-mode-field
ab_case legacy-root
ab_case legacy-configs
ab_case missing
ab_done
