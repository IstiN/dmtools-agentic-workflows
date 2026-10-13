#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Mark machine job started (issue task list)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  repo="${GITHUB_REPOSITORY}"
  leg="${JOB_LEG:-dev} ($(basename "${RUNNER:-agent}" .json))"
  line="- [ ] ▶ ${leg} · [run](${RUN_URL}) · started $(date -u '+%H:%M') ⏳"
  gh issue view "$NUMBER" --repo "$repo" --json body -q .body > /tmp/issue_body.md
  # Collapse trailing blank lines first: body rewrites (jq raw
  # output, earlier appends, agent edits) can leave trailing
  # newlines, and a marker appended after them splits the GitHub
  # task list into separate lists (broken formatting). "$(cat …)"
  # strips ALL trailing newlines; printf adds exactly one back.
  printf '%s\n' "$(cat /tmp/issue_body.md)" > /tmp/issue_body.md
  if grep -q '^## Machine jobs' /tmp/issue_body.md; then
    printf '%s\n' "$line" >> /tmp/issue_body.md
  else
    printf '\n## Machine jobs\n%s\n' "$line" >> /tmp/issue_body.md
  fi
  gh issue edit "$NUMBER" --repo "$repo" --body-file /tmp/issue_body.md
  echo "job marker added: $line"
