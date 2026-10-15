#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# (step: Export custom provider key slots (1-3) → job env) — stage-1 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
i=1
while [ "$i" -le 3 ]; do
  val_var="CUSTOM_PROVIDER_KEY${i}"
  name_var="CUSTOM_PROVIDER_KEY${i}_NAME"
  val="${!val_var:-}"
  name="${!name_var:-}"
  if [ -n "$val" ] && [ -n "$name" ]; then
    case "$name" in *[!A-Z0-9_]*|"")
      echo "::error::CUSTOM_PROVIDER_KEY${i}_NAME '${name}' is not a valid env name (A-Z0-9_)"
      exit 1 ;;
    esac
    printf '%s=%s\n' "$name" "$val" >> "$GITHUB_ENV"
    echo "→ slot ${i} exported as ${name} (value runner-masked)"
  elif [ -n "$val" ] || [ -n "$name" ]; then
    echo "::warning::CUSTOM_PROVIDER_KEY${i}: value without NAME (or NAME without value) — slot skipped"
  fi
  i=$((i + 1))
done
