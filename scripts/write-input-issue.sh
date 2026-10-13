#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Write the issue into the agent input folder) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  # ticket.json carries the tracker-contract fields: dmtools hydrates
  # it into params.ticket for every JS action (Tracker abstraction).
  mkdir -p "input/gh-${NUMBER}"
  gh issue view "$NUMBER" --repo "${GITHUB_REPOSITORY}" \
    --json number,title,body,url,state,labels \
    -q '{key: ("gh-" + (.number|tostring)), number: .number,
         title: .title, body: .body, url: .url, state: .state,
         labels: [.labels[].name]}' \
    > "input/gh-${NUMBER}/ticket.json"
  gh issue view "$NUMBER" --repo "${GITHUB_REPOSITORY}" \
    --json title,body -q '.title, .body' > input/ticket.md
  echo "input/ticket.md: $(wc -l < input/ticket.md) lines"
