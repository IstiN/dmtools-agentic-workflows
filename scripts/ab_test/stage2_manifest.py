"""Stage-2 de-bloat manifest: which factory-teammate.yml run: bodies move to scripts/.

Every entry is byte-extracted from the PRE-de-bloat snapshot (git a4cd62f,
the commit before stage-1 0c3d268 — its factory-teammate.yml carries every
original inline body). `rewrites` are the ONLY permitted content changes:
${{ expressions }} that cannot survive outside the Actions template engine
are swapped for the step-env / runner-native variable holding the identical
value. Gate 4 (run_gates.sh) re-proves script == snapshot body + rewrites,
line for line, on every run.

slice: (start-anchor, end-anchor) — first line matching start anchor through
first line matching end anchor (inclusive), searched inside the step's run
body in order. mode: exec  -> run: bash -e "<kit>/scripts/<name>.sh"
                     source -> run: . "<kit>/scripts/<name>.sh"  (self-heal
                     must export PATH back into the step shell)
                     bg     -> run: [VAR=...] bash -e "...sh" &  (watchdog /
                     stall sidecars; the parent keeps the PID line)
invocation: extra env assignments prefixed on the exec line (values the body
read from the parent step-shell as unexported shell vars — a subshell sees
them, an external script would not).
step_env: env entries ADDED to the step so a rewritten ${{ }} has a carrier.
"""

MANIFEST = [
    dict(script="teammate-dispatch-gate.sh", job="guard",
         step="Decide whether this event is for the agent",
         mode="exec"),
    dict(script="fetch-factory-setup.sh", job="teammate",
         step="Fetch factory-setup (dmtools-agents releases — no tree checkout)",
         mode="exec"),
    dict(script="resolve-parent-config.sh", job="teammate",
         step="Resolve parent config (pack launch.json wins, tree fallback)",
         mode="exec"),
    dict(script="restore-fa-session.sh", job="teammate",
         step="Restore fa session (resume the ticket conversation)",
         mode="exec"),
    dict(script="install-fa-cli.sh", job="teammate",
         step="Install prerequisites (fa; no-op on cache hit)",
         mode="exec"),
    dict(script="install-dmtools-cli.sh", job="teammate",
         step="Install dmtools CLI (pinned release bundle)",
         mode="exec"),
    dict(script="trace-git-credentials.sh", job="teammate",
         step="Trace git credential stack (push-time evidence)",
         mode="exec"),
    dict(script="seed-git-excludes.sh", job="teammate",
         step="Seed local git excludes (factory workspace artifacts)",
         mode="exec"),
    dict(script="write-input-issue.sh", job="teammate",
         step="Write the issue into the agent input folder",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}")]),
    dict(script="write-input-pr.sh", job="teammate",
         step="Write the PR into the agent input folder (PR-anchored runs)",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}")]),
    dict(script="mark-job-started.sh", job="teammate",
         step="Mark machine job started (issue task list)",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}")]),
    dict(script="mark-job-done.sh", job="teammate",
         step="Mark machine job done (issue task list)",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}")]),
    dict(script="dmtools-selfheal.sh", job="teammate",
         step="Run agent (fa provider via runner env overrides)",
         mode="source",
         slice=("# ── dmtools self-heal (self-hosted runners keep a persistent $HOME) ──",
                "          dmtools --version")),
    dict(script="fa-trace-watchdog.sh", job="teammate",
         step="Run agent (fa provider via runner env overrides)",
         mode="bg",
         slice=("# fa-trace staleness watchdog: the fa session streams EVERY turn",
                "          ) &"),
         strip=["  (", "  ) &"],   # standalone loop script; the invocation adds `&`
         invocation='RUN_OUTPUT="${RUN_OUTPUT}"'),
    dict(script="stall-capture.sh", job="teammate",
         step="Run agent (fa provider via runner env overrides)",
         mode="bg",
         slice=("# Stall-capture sidecar (dmd PR-266 hang investigation 2026-09-28):",
                "          ) &"),
         strip=["  (", "  ) &"]),
    dict(script="apply-review-verdict.sh", job="teammate",
         step="Apply the review verdict (review runs only)",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}"),
                   ("needs.guard.outputs.config", "${CONFIG}")]),
    dict(script="close-review-cycle.sh", job="teammate",
         step="Close the review cycle (review runs only)",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}")]),
    dict(script="close-rework-cycle.sh", job="teammate",
         step="Close the rework cycle (rework runs only)",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}")]),
    dict(script="persist-fa-memory.sh", job="teammate",
         step="Persist fa project memory into the repository",
         mode="exec"),
    dict(script="quarantine-fa-session.sh", job="teammate",
         step="Quarantine poisoned fa session",
         mode="exec",
         rewrites=[("steps.run_agent.outcome", "${AGENT_OUTCOME}"),
                   ("github.run_id", "${GITHUB_RUN_ID}"),
                   ("github.run_attempt", "${GITHUB_RUN_ATTEMPT}")],
         step_env=[("AGENT_OUTCOME", "${{ steps.run_agent.outcome }}")]),
    dict(script="collect-fa-crash-log.sh", job="teammate",
         step="Collect fa crash log (uncaught errors live outside the workspace)",
         mode="exec"),
    dict(script="persist-fa-session.sh", job="teammate",
         step="Persist fa session to its git branch",
         mode="exec",
         rewrites=[("needs.guard.outputs.anchor", "${ANCHOR}"),
                   ("needs.guard.outputs.config", "${CONFIG}")],
         step_env=[("ANCHOR", "${{ needs.guard.outputs.anchor }}"),
                   ("CONFIG", "${{ needs.guard.outputs.config }}")]),
    dict(script="hand-issue-to-reviewer.sh", job="teammate",
         step="Hand the issue to the reviewer (dev runs only)",
         mode="exec",
         rewrites=[("github.repository", "${GITHUB_REPOSITORY}")]),
    dict(script="resolve-dmtools-version.sh", job="teammate",
         step="Resolve dmtools CLI version (latest -> current tag)",
         mode="exec"),
    dict(script="verify-prerequisites.sh", job="teammate",
         step="Verify prerequisites",
         mode="exec",
         rewrites=[("inputs.flutter-version", "${FLUTTER_VERSION}")],
         step_env=[("FLUTTER_VERSION", "${{ inputs.flutter-version }}")]),
]

# Stage-1 blocks (already extracted by commit 0c3d268) — not stage-2 work, but
# their A/B scenarios live here too, so render_old_body serves them as well.
# dedent: 10 — both stage-1 blocks sit one nesting level deeper in the
# snapshot (raw content indent 10, not 8); scripts carry the true YAML
# block-scalar body (0-indent — publish-token-usage's `<<'PY'` heredoc
# terminator must sit at column 0 to parse).
STAGE1 = [
    dict(script="publish-token-usage.sh", job="teammate",
         step="Publish leg token usage (fa-tokens ledger -> factory-data)",
         mode="exec", dedent=10),
    dict(script="export-provider-key-slots.sh",
         step="Export custom provider key slots (1-3) → job env",
         mode="exec", job="teammate", dedent=10),
]
