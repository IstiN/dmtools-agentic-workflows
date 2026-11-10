# dmtools-agentic-workflows

**The shared home of the agentic CI/CD workflows** for the
[dmtools](https://github.com/epam/dmtools-dart) ecosystem.

Today: **GitHub Actions** reusable workflows (the machine-loop factory).
**GitLab pipelines** can use the teammate and SM templates under `gitlab/`.
The other native GitLab factory pipelines are still planned.

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
| `factory-sm.yml` | The GitHub machine SM tick (`*/10` cron): reconciles PRs/issues against the loop rules — labels, validation arms, dispatches, merges. Runs `sm_github@latest`. The native GitLab template runs `sm_gitlab@latest` (see below). | `machine-sm.yml` |
| `factory-merge.yml` | The event-driven merge bot: reacts to CI conclusions / label changes and squash-merges approved-green PRs within seconds (idempotent against the SM tick). | `machine-merge.yml` |
| `factory-merge-trigger.yml` | The `pr_approved` merge bot: issue-labeled → linked PR → CLEAN → squash-merge → label removed → issue comment. Parameterized linking (body `Closes #N`, branch `N-…`/`gh-N`, PR-label reverse mapping). | `merge-trigger.yml` |
| `factory-sm-kicker.yml` | The SM watchdog: dispatches an SM tick when the cron was missed; re-dispatches validation CI on codeless PR heads that carry no required contexts. | `sm-kicker.yml` |

## Native GitLab teammate pipeline

Include the hidden `.factory-teammate` job from
`gitlab/factory-teammate.yml` in the caller's `.gitlab-ci.yml`. Pin the
include and `FACTORY_HOME_REF` to the **same full immutable SHA**:

```yaml
include:
  - remote: https://raw.githubusercontent.com/IstiN/dmtools-agentic-workflows/<full-SHA>/gitlab/factory-teammate.yml

ai-teammate:
  extends: .factory-teammate
  # Supply your trusted Linux runner image and/or runner tags here.
  variables:
    FACTORY_HOME_REF: <full-SHA>
  resource_group: teammate-$CI_PROJECT_ID-$FACTORY_ISSUE-$FACTORY_MR
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && ($CI_PIPELINE_SOURCE == "api" || $CI_PIPELINE_SOURCE == "trigger" || $CI_PIPELINE_SOURCE == "web")'
```

Dispatch a pipeline on the default branch with exactly one project-local
IID: `FACTORY_ISSUE` or `FACTORY_MR`. `FACTORY_LEG` accepts `dev`, `bug`,
`story`, `review`, or `rework`; empty derives from fresh labels and machine
assignment. MR anchors support only review/rework. `FACTORY_REASON` is an
audit message; `FACTORY_CHECKOUT_REF` optionally selects the worktree ref
(MR anchors default to `refs/merge-requests/<IID>/head`). Issue/label webhooks
and scheduling belong to the caller or an external dispatcher: GitLab does
not automatically start pipelines for issue-label changes.

Caller requirements:

- A trusted Linux runner with Bash, Git, curl, jq, Node.js, GitHub CLI,
  unzip, tar, and GNU `timeout`. Install agent-work toolchains in the
  caller's image or `before_script`; no Java/Flutter/etc. versions are
  selected by this template.
- Masked `GITLAB_TOKEN` (`api` and `write_repository` scopes, with project
  access) and `SOURCE_GITHUB_TOKEN` (GitHub release downloads). Set provider
  secrets as masked CI variables, including `ZAI_CODE_KEY`, its numbered
  fallback slots, `KIMI_REVIEW_KEY`, or `CUSTOM_PROVIDER_KEY1..3` with matching
  `CUSTOM_PROVIDER_KEY1_NAME..3_NAME`. Provider queues are passed through
  as `ENV_VAR_DEV_QUEUE` and `ENV_VAR_REVIEW_QUEUE`.
- If `GITLAB_DEV_TOKEN` is set, the template selects it at runtime as
  `GITLAB_TOKEN` for development/rework work, and uses `GITLAB_REVIEWER_TOKEN`
  for review when `DMTOOLS_GITLAB_TEAMMATES: "multiple"`. In multi-teammate
  mode both tokens are required for their respective legs. This runtime
  selection ensures project/group variables named `GITLAB_TOKEN` cannot
  override the selected role token.
- Set `DMTOOLS_GITLAB_INSTALL_TOOLS: "true"` to install the Debian/Ubuntu
  runner dependencies with apt. It defaults to false; otherwise the caller
  must provide the required tools in its runner image.
- Set `DMTOOLS_GITLAB_FACTORY_HELPERS: "true"` to enable the factory-specific
  Git authentication cleanup, assignee resolution, post-development MR
  verification/labels, and scheduled issue/MR queue scanning. The scanner
  handles assigned `agent:dev` issues plus `agent:review`/`agent:rework`
  issues and MRs without requiring the development label or assignment.
  It skips holds/busy legs/questions, prioritizes rework, and deduplicates
  related issue/MR dispatches. These factory behaviors are opt-in for other
  callers; callers that override scan rules must set `FACTORY_HOME_REF` and
  supply the required tools and role-token setup.
- `.dmtools/config.js` with `sm.runners.bug`/`story` (or `dev`), `review`,
  and `rework`. **These runners must support GitLab**: GitHub-only packs
  cannot be ported by changing CI YAML. The factory supplies GitLab
  connection variables, `jobParams.owner`/`repo`/`scmProvider`/`machineAuthor`,
  and tracker-shaped `input/gl-<IID>/ticket.json` or
  `input/mr-<IID>/ticket.json`. Review runners must write a structured
  `decision` or `verdict` in `outputs/pr_review.json` (`APPROVE`,
  `CHANGES_REQUESTED`, or `BLOCK`). Issue reviews resolve exactly one open
  local MR via GitLab's related-MRs API; runners must publish that linkage.
- `AGENTS_VERSION`, `DMTOOLS_VERSION`, and `FA_VERSION` default to `latest`;
  concrete release tags pin tooling. `AGENT_HANDLE` identifies the machine
  account; `MAX_AUTO_REWORK_ROUNDS` defaults to `2`.

The template honors closed/held items, routes dev/review/rework, posts job
start/completion notes, and consumes completed review/rework queue labels. Failed
or cancelled rework restores `agent:rework`, even if a dispatcher consumed it
before the job started; only the busy status is cleared. Successful
development/rework queues review unless the runner requested human input.
An `ai_developed` issue without a new development request does not fall back
to development when a review/rework label disappears. `rework-round:N` is
history, not a queue request: re-add `agent:rework` or dispatch an explicit
`FACTORY_LEG=rework` to recover an older consumed request.
Approval labels require successful CI on the captured MR head and GitLab
mergeability; missing verdicts and ambiguous/changing MR heads escalate to
`needs-human`. Rework is bounded and provider exhaustion parks the lane with
`provider_quota`. An approval awaiting CI is reported but not automatically
reconciled here: the caller must re-dispatch review or supply a reconciler.
Merging remains caller-owned.

The agent-pack SM currently dispatches `workflow_file=ai-teammate.yml` with
`issue`, `pr`, and `leg` inputs, sometimes on the MR source branch. Native
callers must admit these API pipelines and map the inputs to `FACTORY_ISSUE`,
`FACTORY_MR`, and `FACTORY_LEG` in job rules. Keep the explicit leg: the SM
may consume a request label immediately after accepting the dispatch.

Run the mocked GitLab lifecycle regression tests with
`node --test tests/gitlab-templates.test.mjs` (Bash and jq required).

Workspace `.fah` session/memory state persists on `fa-sess/gl-<IID>` or
`fa-sess/mr-<IID>`; timed-out agent sessions are discarded. Runners storing
sessions outside `.fah` must provide their own persistence. Session/memory
is not committed to the default branch. Diagnostic artifacts upload even on
failure. The caller's `resource_group` must serialize all legs for an anchor;
the hidden template owns neither triggers nor concurrency. Do not expose
write/provider tokens to untrusted pipeline definitions or fork worktrees.

## Native GitLab SM pipeline

Include `gitlab/factory-sm.yml` at an immutable full SHA and extend its
hidden `.factory-sm` job in the caller's `.gitlab-ci.yml`. The caller owns
the runner image/tags, pipeline schedule, trigger rules, and concurrency:

```yaml
include:
  - remote: https://raw.githubusercontent.com/IstiN/dmtools-agentic-workflows/<full-SHA>/gitlab/factory-sm.yml

machine-sm:
  extends: .factory-sm
  # Supply your trusted Linux runner image and/or runner tags here.
  resource_group: machine-sm-$CI_PROJECT_ID
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && ($CI_PIPELINE_SOURCE == "schedule" || $CI_PIPELINE_SOURCE == "web" || $CI_PIPELINE_SOURCE == "api")'
```

Create a GitLab pipeline schedule (for example `*/10 * * * *`) on the default
branch. Use a trusted Linux runner with Bash, Git, curl, jq, Node.js, GitHub
CLI, and unzip. Keep `.dmtools/config.js` in the calling repository and set
masked `GITLAB_TOKEN` (`api` scope, project access) and
`SOURCE_GITHUB_TOKEN` (GitHub release downloads) as caller CI variables.
If `GITLAB_DEV_TOKEN` is set, the SM selects it as `GITLAB_TOKEN` at runtime.
Set `DMTOOLS_GITLAB_INSTALL_TOOLS: "true"` to let the template install tools
with apt; otherwise keep the required tools in the caller's runner image.

| CI variable | Purpose | Default |
|---|---|---|
| `AGENTS_VERSION` | Agent-pack release tag | `latest` |
| `DMTOOLS_VERSION` | dmtools CLI release tag | `latest` |
| `SM_GITLAB_PROJECT` | Target `namespace/project`, including nested groups | `$CI_PROJECT_PATH` |
| `GITLAB_BASE_PATH` | GitLab instance URL without `/api/v4` | `$CI_SERVER_URL` |
| `SM_DRY_RUN` | `true` logs the plan without acting; `false` runs live | `false` |
| `SM_MACHINE_AUTHOR` | Deployment's machine login | Empty, uses pack/config default |
| `SM_PARALLEL_WORKERS` | Parallel read workers, enabled for values >= 2 | `0`, sequential |

The template validates inputs before installing anything, resolves release
tags at run time (explicit tags are checked and never floated), installs
the CLI with an authenticated release-download fallback, and runs
`sm_gitlab@latest` from the resolved agents release registry. Project identity
rides `jobParams.owner`/`repo` and the GitLab connection variables. JSON
overrides are built with jq, and diagnostic output uploads even on failure.
`.dmtools/config.js` `repository.owner`/`repo` take precedence in the pack;
leave them unset or align them with the selected GitLab project. Configure
the pack's dispatch runners for the caller's native teammate pipeline.

**Engine limitation:** `sm_gitlab` currently enables dispatch rules only.
Merges, validation, branch updates, and verdict reconciliation remain
GitHub-only in the released engine; this CI template does not implement
those missing engine rules or accept their GitHub-only inputs.

**Contract change:** `.github/workflows/factory-sm.yml` is now GitHub-only.
The `scm-provider`, `gitlab-project`, `gitlab-base-path` inputs and
`GITLAB_TOKEN` secret have been removed from that reusable workflow. Existing
immutable pins keep the old behavior; callers adopting this revision for
GitLab must migrate to the native template above.

## The SM kicker: why every machine repo needs it

**The problem it solves.** `machine-sm.yml` drives the whole loop from a
`schedule:` cron (`*/10`). GitHub **silently drops scheduled workflows** on
repos it deems quiet — no error, no run, nothing in the UI: the cron simply
stops firing, for hours, then may come back. A dead SM tick means nothing
reconciles: validations never arm, merges never queue, PRs pile up
validated-but-parked. Live evidence: on 2026-10-01 `epam/dmtools-dart`'s
machine-sm schedule was dead 14:44→18:38 while GitHub still showed the cron
configured; two validated PRs sat BLOCKED until a manual `workflow_dispatch`
revived the chain. dmtools-agents had the same class of gap (only manual
dispatches ran for hours).

**How it works.** The kicker is a second, independent heartbeat that cannot
be dropped together with the SM cron (different workflow, different
schedule offset — `13,43 * * * *`):

- on its own schedule and on every **non-main push**, it checks SM liveness
  (when did machine-sm last run live?) and dispatches a tick if the SM is
  stale;
- on PR-head pushes it re-dispatches validation CI on **codeless heads**
  whose required contexts never concluded (the "checks: none" stall class).

**Wiring a repo (the stub).** Drop this as `.github/workflows/sm-kicker.yml`
— inputs are the ONLY repo-specific parts:

```yaml
name: SM kicker
on:
  push:
    branches-ignore: [main]
  schedule:
    - cron: '13,43 * * * *'   # offset from the SM cron so the two never race
  workflow_dispatch:
permissions:
  actions: write
  contents: read
  pull-requests: read
  checks: read
jobs:
  kicker:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/factory-sm-kicker.yml@<full-SHA>
    with:
      sm_workflow: machine-sm.yml      # the SM stub this repo dispatches
      ci_workflow: quality.yml         # the validation CI to re-dispatch
      ci_display_name: Quality         # its display name in logs
      required_contexts: 'static,gate' # contexts that must conclude on PR heads
```

Pin rules from the freeze contract apply (full immutable SHA; the guard test
fails short/branch pins). **Rule of thumb: any repo carrying
`machine-sm.yml` must carry `sm-kicker.yml` in the same PR** — a machine
loop without its watchdog is the stall we just lived through.

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
- GitLab pipelines: same freeze contract, `gitlab/` namespace,
  mirrored semantics — the stub/pin discipline is CI-system-agnostic.
