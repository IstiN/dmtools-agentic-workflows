#!/usr/bin/env bash
# A/B: Fetch factory-setup (dmtools-agents releases — no tree checkout)
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init fetch-factory-setup.sh

seed_case() {
  # deterministic factory-setup zip
  mkdir -p fixtures
  local T; T=$(mktemp -d); mkdir -p "$T/pk/setup" "$T/pk/configs"
  printf 'cache.sh-stub\n'        > "$T/pk/setup/cache.sh"
  printf '{"launch":"zip"}\n'     > "$T/pk/configs/pr_review.json"
  (cd "$T/pk" && zip -qr "${CASE}/fixtures/factory-setup-9.zip" setup configs)
  rm -rf "$T"
  : > gh_rules.tsv
  case "${AB_CASE_ID}" in
    registry-var)
      cat > gh_rules.tsv <<RULES
release download	file	${CASE}/fixtures/factory-setup-9.zip
RULES
      echo "PACK_TAG=agents-rel-9" >> /dev/null ;;
    knob-pinned)
      cat > gh_rules.tsv <<RULES
release download	file	${CASE}/fixtures/factory-setup-9.zip
RULES
      ;;
    url-resolver)
      cat > gh_rules.tsv <<RULES
release download	file	${CASE}/fixtures/factory-setup-9.zip
RULES
      ;;
    newest-fallback)
      cat > gh_rules.tsv <<RULES
release list	json	${CASE}/fixtures/releases.json
release download	file	${CASE}/fixtures/factory-setup-9.zip
RULES
      printf '[{"tagName":"agents-rel-3"},{"tagName":"other-v1"}]\n' > fixtures/releases.json ;;
    mounted-tree)
      mkdir -p seed/factory-agents ;;
    no-release) cat > gh_rules.tsv <<RULES
release list	json	${CASE}/fixtures/releases-empty.json
RULES
      printf '[]\n' > fixtures/releases-empty.json ;;
  esac
}

case_env() {
  echo "GH_TOKEN=stub-token"
  # the workflow step env always defines both (possibly empty) — mirror that
  echo "PACK_TAG=${PACK_TAG_OVERRIDE:-}"
  echo "AGENTS_KNOB=${AGENTS_KNOB_OVERRIDE:-}"
}

PACK_TAG_OVERRIDE=agents-rel-9             ab_case registry-var
PACK_TAG_OVERRIDE=agents-rel-9 AGENTS_KNOB_OVERRIDE=agents-rel-7 ab_case knob-pinned
PACK_TAG_OVERRIDE='https://github.com/IstiN/dmtools-agents/releases/tag/agents-rel-5' ab_case url-resolver
ab_case newest-fallback
ab_case mounted-tree
ab_case no-release
ab_done
