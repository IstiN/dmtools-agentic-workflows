#!/usr/bin/env bash
# A/B (stage-1 block): Export custom provider key slots (1-3) → job env
source "$(dirname "${BASH_SOURCE[0]}")/ab_test_lib.sh"
ab_init export-provider-key-slots.sh

seed_case() { :; }

case_env() {
  case "${AB_CASE_ID}" in
    all-slots)
      echo "CUSTOM_PROVIDER_KEY1=val-one";  echo "CUSTOM_PROVIDER_KEY1_NAME=ZAI_CODE_KEY"
      echo "CUSTOM_PROVIDER_KEY2=val-two";  echo "CUSTOM_PROVIDER_KEY2_NAME=KIMI_REVIEW_KEY"
      ;;
    half-configured)
      echo "CUSTOM_PROVIDER_KEY1=val-one"; echo "CUSTOM_PROVIDER_KEY1_NAME=ZAI_CODE_KEY"
      echo "CUSTOM_PROVIDER_KEY2=";        echo "CUSTOM_PROVIDER_KEY2_NAME=ORPHAN_NAME"
      ;;
    invalid-name)
      echo "CUSTOM_PROVIDER_KEY1=val";     echo "CUSTOM_PROVIDER_KEY1_NAME=bad-name!"
      ;;
    no-slots) : ;;
  esac
}

ab_case all-slots
ab_case half-configured
ab_case invalid-name
ab_case no-slots
ab_done
