#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Seed local git excludes (factory workspace artifacts)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  {
    echo '# factory workspace artifacts (seeded per-run, never commit)'
    echo '.codegraph/'
    echo '.dmtools/fa-trace.log'
    echo '.dmtools/run-output.txt'
    echo '.dmtools/stall-capture.log'
    echo '.dmtools/fa-sessions/'
    echo '.dmtools/copilot-sessions/'
    echo '.fah/bash_jobs/'
    echo '# the factory clone itself: an in-index gitlink without'
    echo '# .gitmodules breaks every actions/checkout with submodules'
    echo 'factory-agents/'
  } >> .git/info/exclude
