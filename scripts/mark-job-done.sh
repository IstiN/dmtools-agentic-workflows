#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Mark machine job done (issue task list)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  repo="${GITHUB_REPOSITORY}"
  case "${JOB_RESULT}" in
    success) mark="✅" ;;
    failure) mark="❌" ;;
    cancelled) mark="🚫" ;;
    *) mark="⚠️ ${JOB_RESULT}" ;;
  esac
  end_ts="$(date -u '+%H:%M')"
  gh issue view "$NUMBER" --repo "$repo" --json body -q .body > /tmp/issue_body.md
  awk -v url="(${RUN_URL})" -v mark="$mark" -v end="$end_ts" '
    index($0, url) > 0 && $0 ~ /^- \[ \]/ {
      line = $0
      sub(/^- \[ \] /, "- [x] ", line)
      if (match(line, /started [0-9][0-9]:[0-9][0-9]/)) {
        st = substr(line, RSTART, RLENGTH)
        sub(/started [0-9][0-9]:[0-9][0-9] .*$/, st " · done " end " " mark, line)
      }
      $0 = line
    }
    { print }
  ' /tmp/issue_body.md > /tmp/issue_body_new.md
  if ! cmp -s /tmp/issue_body.md /tmp/issue_body_new.md; then
    gh issue edit "$NUMBER" --repo "$repo" --body-file /tmp/issue_body_new.md
    echo "job marker flipped to [x] ${mark}"
  else
    echo "::warning::start marker not found for ${RUN_URL} — nothing to flip"
  fi
