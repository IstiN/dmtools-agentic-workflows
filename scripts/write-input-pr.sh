#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Write the PR into the agent input folder (PR-anchored runs)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  mkdir -p "input/pr-${PR_NUMBER}"
  gh pr view "$PR_NUMBER" --repo "${GITHUB_REPOSITORY}" \
    --json number,title,body,url,state,labels \
    -q '{key: ("pr-" + (.number|tostring)), number: .number,
         title: .title, body: .body, url: .url, state: .state,
         labels: [.labels[].name]}' \
    > "input/pr-${PR_NUMBER}/ticket.json"
  gh pr view "$PR_NUMBER" --repo "${GITHUB_REPOSITORY}" \
    --json title,body -q '.title, .body' > input/ticket.md
  echo "input/ticket.md: $(wc -l < input/ticket.md) lines"
