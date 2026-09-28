# AGENTS.md — rules for working in dmtools-agentic-workflows

This repo is the **frozen machine-loop home** for the dmtools agent
ecosystem. Read `README.md` first — it defines the freeze contract.

## 1. Non-negotiable rules

1. **Callers pin by immutable SHA; we never break a pinned surface.** Any
   change to a workflow file here is a contract change for every caller.
   Treat edits like API breaks: bump-worthy only, small, and announced in
   the commit/PR so callers can update their pin + guard constant in the
   same motion.
2. **Versions never live in these files.** Agent code comes from
   dmtools-agents releases (`vars.AGENTS_VERSION`), the CLI from
   dmtools-dart releases (`vars.DMTOOLS_VERSION`). Hardcoding a version or a
   release tag here violates the freeze model.
3. **`secrets` and `vars` resolve from the CALLER.** These workflows run as
   reusable (`workflow_call`) units; `vars.*`/`secrets.*` referenced here
   come from the calling repository. Never assume this repo's settings.
4. **No `concurrency` blocks in reusable workflows.** GitHub ignores a
   callee's concurrency; a caller+callee group-name collision fails every
   run at startup with zero jobs (live bisect 2026-09-22). The caller owns
   grouping.
5. **No new required inputs/secrets without a caller-migration plan.**
   Adding a required `workflow_call` input breaks every existing stub at
   validation time. New knobs must be optional with a safe default.

## 2. GitHub quirks encoded here (do not "clean up")

- `github.token` arrives EMPTY through reusable-call inputs/secrets
  (live-verified both channels) — silent pushes use the callee's OWN
  `github.token` reference. Callers pass it via the documented
  `silent-token` input instead.
- `secrets: inherit` does NOT satisfy a required named secret at call
  validation (live bisect run 35275493724) — callers map explicitly, and
  the mapped set must EXACTLY equal the declared set.
- Boolean-typed reusable inputs reject expressions — boolean knobs travel
  as STRING inputs (`dryRun: 'true'`).
- Cron is best-effort: scheduled runs silently vanish under load. That is
  why `factory-merge.yml` exists as the event-driven fast path.

## 3. Layout

- `.github/workflows/factory-sm.yml` — the SM tick (version resolve → CLI
  install → `dmtools run sm_github@latest` from the target repo checkout).
- `.github/workflows/factory-merge.yml` — the merge bot (same skeleton,
  `machine_merge@latest`, 5-minute timeout).

## 4. Validation before merging any change

- Reusable workflows have no standalone CI here — they are exercised by the
  callers' stubs. Before merging a non-trivial change, dispatch a **dry
  tick** in a caller repo (`gh workflow run machine-sm.yml -f dryRun=true`
  in dmtools-dart) and confirm the reconcile step logs the plan with no
  actions.
- Keep the header comment of each workflow in sync with reality — it is the
  caller's primary documentation.

## 5. Session log

- **2026-09-28:** repo repurposed — old `reusable-*` workflows deleted,
  `factory-sm.yml` / `factory-merge.yml` migrated in from
  `IstiN/dmtools-agents@f377609` and converted to the agents-by-version
  model (pack-based run, `vars.AGENTS_VERSION` / `vars.DMTOOLS_VERSION`,
  `factory_ref` input removed). README + this file added. First caller:
  `epam/dmtools-dart` (#297).
