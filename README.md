# dmtools-agentic-workflows

**The frozen home of the machine-loop workflows** for the
[dmtools](https://github.com/epam/dmtools-dart) agent ecosystem.

Target repositories (e.g. `epam/dmtools-dart`, `IstiN/dmtools-agents`) carry
only **thin stubs** — trigger definitions and a single `uses:` call pinned to
an immutable SHA of this repo. Everything that can move (agent code, the
dmtools CLI) resolves from **releases at run time**, so a pinned SHA never
goes stale and the stubs never need edits to bump a version.

## What lives here

| Workflow | What it does | Caller stub |
|---|---|---|
| `factory-sm.yml` | The machine SM tick (`*/10` cron): reconciles PRs/issues against the loop rules — labels, validation arms, dispatches, merges. Runs the SM engine as a **versioned agent pack** (`dmtools run sm_github@latest`) fetched from the dmtools-agents release selected by `vars.AGENTS_VERSION`. | `machine-sm.yml` in the caller |
| `factory-merge.yml` | The event-driven merge bot: reacts to CI conclusions / label changes / head pushes and squash-merges approved-green PRs within seconds (idempotent against the SM tick). Runs `machine_merge@latest` as a pack. | `machine-merge.yml` in the caller |

## The freeze contract

1. **Pin by immutable SHA.** Callers reference
   `IstiN/dmtools-agentic-workflows/.github/workflows/<name>.yml@<full-SHA>`.
   Never a branch ref — a branch executes whatever sits at its head at run
   start.
2. **Never edit a frozen workflow for a version bump.** Versions are caller
   repo **variables** (Settings → Secrets and variables → Actions):
   | Variable | Controls | Default |
   |---|---|---|
   | `AGENTS_VERSION` | dmtools-agents release tag (`latest` or `agents-rel-…`) | `latest` |
   | `DMTOOLS_VERSION` | dmtools-dart CLI release tag (`latest` or `vX.Y.Z`) | `latest` |
3. **Changing a workflow here** means every caller bumps its pinned SHA
   (each caller guards the pin with a test, e.g.
   `factory_stub_ref_test.dart` in dmtools-dart, so a drifted pin fails CI).

## How a caller integrates

Add two thin stubs (see `epam/dmtools-dart` `.github/workflows/machine-sm.yml`
/ `machine-merge.yml` for the reference copies):

```yaml
# machine-sm.yml
on:
  schedule: [{cron: '*/10 * * * *'}]
  workflow_dispatch: {inputs: {dryRun: {type: boolean, default: true}}}
permissions: {contents: write, issues: write, pull-requests: write,
              checks: write, actions: write}
jobs:
  sm:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/factory-sm.yml@<SHA>
    with:
      machine-author: <bot-login>        # the machine's GitHub login (#687)
      validation-checks: '["check-a"]'   # optional: bridge-free check stamps
      state-publish: '{"channel":"release",...}' # optional: factory-state
      parallel-workers: '4'              # optional: runAsync read fan-out
      dryRun: ${{ github.event.inputs.dryRun || 'false' }}
      silent-token: ${{ github.token }}
    secrets:
      SOURCE_GITHUB_TOKEN: ${{ secrets.SOURCE_GITHUB_TOKEN }}
      SILENT_GH_TOKEN: ${{ secrets.SILENT_GH_TOKEN }}   # optional
```

Rules that keep the loop safe (learned live, encoded in the factories):

- **No caller-side `concurrency` on the SM group** — the factory owns
  `group: machine-sm`; a caller declaring the same group deadlocks the called
  workflow (it waits forever on a group its own caller holds).
- **Secrets are explicitly mapped**, never `inherit` — the factory declares
  `SOURCE_GITHUB_TOKEN` required; `inherit` fails required-secret validation
  at call time (live bisect: startup failure, zero jobs).
- **`github.token` does not cross the reusable-call boundary** through
  inputs/secrets (both arrive empty) — a called workflow references its OWN
  `github.token` directly for silent (no-workflow-triggering) pushes.
- **Run the SM from the target-repo checkout root** — the pack's config
  loader discovers `.dmtools/config.js` (machine author, Jira fields,
  `sm.runners`) from the caller's working directory, exactly like the old
  submodule checkout did.

## Version resolution at run time

Each factory step:

1. Resolves the version knobs (`latest` → newest release tag via
   `gh api repos/<owner>/<repo>/releases/latest`; an explicit tag is
   existence-checked — a typo'd pin fails loudly, not silently).
2. Installs the dmtools CLI from the resolved dmtools-dart release bundle
   (`install.sh` ships as a release asset).
3. Points `DMTOOLS_PACK_REGISTRY` at the resolved dmtools-agents release
   asset directory and runs `dmtools run <agent>@latest` — the CLI resolves
   the pack version from the release's `catalog.json`, downloads
   `<agent>-<version>.zip`, verifies the sha256 sidecar + the manifest's
   per-file inventory, caches it under `~/.dmtools/packs/`, and rewrites the
   config's path keys into the pack root.

## Scope notes

- `factory-teammate.yml` is **not here yet** — the teammate leg is still
  pinned inside `IstiN/dmtools-agents` (its guard job and `scripts/` closure
  are coupled to an agents checkout). Callers keep the historical pin until
  the follow-up migration.
- The old generic reusable workflows (`reusable-*`) were removed: this repo
  is the machine-loop home now, not a generic workflow library.
