# dmtools-agentic-workflows

**The shared home of the agentic CI/CD workflows** for the
[dmtools](https://github.com/epam/dmtools-dart) ecosystem.

Today: **GitHub Actions** reusable workflows (the machine-loop factory).
Tomorrow (planned): the same factory surface for **GitLab pipelines** lives
here too — one repo, every CI system the ecosystem runs on.

Target repositories (`epam/dmtools-dart`, `IstiN/flutter_agent_harness`,
`IstiN/dmtools-agents`, …) carry only **thin stubs** — trigger definitions
and a single `uses:` call pinned to an immutable SHA of this repo.
Everything that can move (agent code, the dmtools CLI) resolves from
**releases at run time**, so a pinned SHA never goes stale and the stubs
never need edits to bump a version.

## What lives here

| Workflow | What it does | Caller stub |
|---|---|---|
| `factory-teammate.yml` | The issue-driven AI teammate: dev / review / rework legs, sessions, verdict, memory. Runs the agent pack (`bug_development@latest` …) from the dmtools-agents release selected by `factory_ref` / `vars.AGENTS_VERSION`. | `ai-teammate.yml` |
| `factory-sm.yml` | The machine SM tick (`*/10` cron): reconciles PRs/issues against the loop rules — labels, validation arms, dispatches, merges. Runs the SM engine as a versioned agent pack (`sm_github@latest`). | `machine-sm.yml` |
| `factory-merge.yml` | The event-driven merge bot: reacts to CI conclusions / label changes and squash-merges approved-green PRs within seconds (idempotent against the SM tick). | `machine-merge.yml` |
| `factory-merge-trigger.yml` | The `pr_approved` merge bot: issue-labeled → linked PR → CLEAN → squash-merge → label removed → issue comment. Parameterized linking (body `Closes #N`, branch `N-…`/`gh-N`, PR-label reverse mapping). | `merge-trigger.yml` |
| `factory-sm-kicker.yml` | The SM watchdog: dispatches an SM tick when the cron was missed; re-dispatches validation CI on codeless PR heads that carry no required contexts. | `sm-kicker.yml` |

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
3. **`secrets` and `vars` resolve from the CALLER.** These are reusable
   (`workflow_call`) units; `vars.*`/`secrets.*` come from the calling
   repository. Never assume this repo's settings.
4. **Engine pin ≠ factory pin.** The factory home pin (`uses:`) moves only
   when a workflow here changes; the engine pin (`factory_ref` input, a
   dmtools-agents SHA) moves with the engine. Two independent pins — never
   conflate them, never bump them together by reflex.

## How to consume (wire a repo to the factory)

1. **Stubs.** Copy the caller stubs from a wired repo (dmd is the reference):
   `ai-teammate.yml`, `machine-sm.yml`, `machine-merge.yml`,
   `merge-trigger.yml`, `sm-kicker.yml`. Point each `uses:` at the full SHA
   you adopted and adjust the repo-specific inputs (CI workflow file/display
   name, required contexts, runner labels).
2. **Triggers stay repo-side.** `on:` blocks cannot be parameterized — the
   stub declares them (issues/events/cron/workflow_run on YOUR CI name) and
   hands the event to the factory via the reusable call.
3. **Repo wiring.** `.dmtools/config.js` with `sm.runners` (leg → runner
   JSON, packs referenced as `<pack>@latest`), the repo vars
   (`DMTOOLS_VERSION`, `AGENTS_VERSION` optional — latest default), and the
   secrets the legs need (`SOURCE_GITHUB_TOKEN`; `ZAI_CODE_KEY` /
   `KIMI_REVIEW_KEY` for the fa/zai runners).
4. **Branch protection.** Required checks = your validation CI's contexts,
   strict up-to-date. The machine only merges CLEAN PRs, so protection
   defines "ready" — but require only checks that can actually conclude on
   PR heads (tag-only gates must NOT be required).
5. **Guards.** Port `test/machine_kit/factory_stub_ref_test.dart` from dmd:
   every stub must pin an immutable 40-hex SHA; the engine pin rides
   `factory_ref` (or resolves from releases); secrets mapped explicitly
   where the callee declares them.

## How to add / change a workflow here

- A change to any workflow file is a **contract change for every pinned
  caller**. Keep it small, announce it in the commit/PR, and let callers
  re-pin + update their guard constants in the same motion.
- New reusable workflows follow the house pattern: `workflow_call` inputs
  with safe defaults, everything repo-specific parameterized, no versions
  hardcoded, `concurrency` owned by the caller (never declared inside a
  reusable unit).
- GitLab pipelines (future): same freeze contract, `gitlab/` namespace,
  mirrored semantics — the stub/pin discipline is CI-system-agnostic.
