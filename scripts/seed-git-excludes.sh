#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Seed local git excludes (factory workspace artifacts)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
mkdir -p .git/info
touch .git/info/exclude
for pattern in \
  '.codegraph/' \
  '.dmtools-target-workingdir' \
  '.dmtools/fa-trace.log' \
  '.dmtools/run-output.txt' \
  '.dmtools/stall-capture.log' \
  '.dmtools/credential-helper.log' \
  '.dmtools/fa-sessions/' \
  '.dmtools/copilot-sessions/' \
  '.fah/bash_jobs/' \
  '.fah/trajectories/' \
  'factory-agents/'
do
  if ! grep -qxF "$pattern" .git/info/exclude 2>/dev/null; then
    echo "$pattern" >> .git/info/exclude
  fi
done
