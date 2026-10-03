---
name: factory-backstop-watch
description: Supervise autonomous agent factories (the machine loop) across repositories — SM tick health, validation lanes, merge conveyors, and dead-zone classes with live remediation rules. Use when an agent factory stalls (PRs park forever, validations never dispatch, verdicts never consumed, legs startup-fail) or when standing watch over fa / dmtools-agents / dmtools-dart style repos where a state machine drives PRs through review → validation → merge.
---

# Factory Backstop Watch

The machine loop is a distributed state machine assembled from GitHub pieces
(labels + workflow_dispatch + reusable workflows + state files on data
branches). It has no supervisor of its own — this skill is that supervisor.

## 1. The machine (what "healthy" means)

Conveyor per PR: `pr_approved` (human/AI review) → SM arms `ai_validating`
+ dispatches the Quality/validation workflow on the PR head → green latches
`ai_validated` → Machine Merge Bot merges when `mergeStateStatus: CLEAN`.
Validation is a **serial lane** (limit 1) per repo; queue order is FIFO by
approval time, not by PR number.

Standing inputs:

- **machine-sm.yml** ticks (cron `*/10`) — the state machine's heart.
- **sm-kicker.yml** (cron `13,43`) — liveness probes + wake-ups.
- Both crons are flaky (GitHub silently dropped both on one repo for 1.5h
  once). A stuck conveyor with zero recent ticks = kick a **real** tick:
  `gh workflow run machine-sm.yml -F dryRun=false` — in repos where the
  workflow's `dryRun` input defaults to `true`, a bare kick runs a dry tick
  that changes nothing. Check the input default per repo before kicking.

## 2. Health cycle (every ~10 min per repo)

1. **Tick health**: last `machine-sm.yml` conclusion. Failure → one real
   kick; two consecutive failures → escalate.
2. **Legs** (AI Teammate workflows): last runs; any failure or a leg
   `in_progress` > 3h → escalate.
3. **Verdict consumption**: any PR that is `pr_approved` + `ai_validated` +
   CLEAN + green checks and still unmerged after ~20m → kick a tick; after
   two ticks → escalate "verdict not consumed".
4. **Validating lane**: the `ai_validating` set must churn. Unchanged > 45m
   → check a run is actually in flight on the head
   (`gh run list --branch <head>`); nothing in flight = **lost dispatch** →
   redispatch the validation workflow on that ref and note it.
5. **Release chore PRs** (`chore(release)`) open > 15m → escalate; they
   should live minutes.

## 3. Dead-zone classes (each froze a real conveyor)

| Class | Symptom | Root cause | Fix |
|---|---|---|---|
| **Park without reset** | PR parked `validation_failed`, vendor pushes fixes, nothing ever revalidates | unpark probe only ran in a `mergeState: BEHIND` rule; pushed-to heads are never BEHIND | park-reset rule without mergeState filter + validate_pr backstop (dmtools-agents#668) |
| **Cancelled-only checks** | armed PR stuck: checks fold to `pending` forever, nothing lands | concurrency cancelled the only validation run; no rule treats cancelled-only as lost | treat cancelled-older-than-stale as lost → redispatch (issue #632) |
| **Kicker-green born PR** | PR created from a pre-pushed branch never gets validated | kicker stamped green bookkeeping checks on the head before PR creation; validation lane matches only `checks: none/pending` | lane must ignore bookkeeping checks (issue #628) |
| **Permissions ceiling** | every dispatch `startup_failure`, zero jobs | caller stub granted `contents: read`; reusable factory workflow requests the write set and can never raise rights above the caller | stub must grant the factory's full permission ceiling (dmtools-agents#669) |
| **Duplicate YAML keys** | dispatches 422 (`X is already defined`), event triggers dead, phantom path-named workflow registration | merge residue duplicating keys | dedup (dmtools-agents#671) |
| **Lost dispatch** | validating label armed, no run ever appears | GitHub dropped the dispatch (cron-flake class) | redispatch validation on the head manually |

## 4. Hard rules

- **Never weaken gates** (CRAP thresholds, coverage, test suites), never
  `--no-verify`, never merge red.
- **Never fix vendor/guest PR content.** Parks clear on the vendor's own
  pushes (park-reset) or not at all.
- `blocked` label = owner hold; invisible to all rules; never remove it.
- A leg failing twice on the same PR → stop and escalate, don't retry blind.

## 5. Diagnosis kit

- **startup_failure bisection**: push a minimal probe workflow to a scratch
  branch (dispatch + one job calling the reusable workflow), dispatch it,
  read the annotation: scrape the run page HTML — the full error lives in
  the annotation div. Delete the probe branch when done.
- **Event-trigger deafness**: check `gh api repos/<o>/<r>/actions/workflows`
  for the workflow's `state`, then `?event=<type>` runs; a path-named
  workflow in run lists = broken registration (usually duplicate keys).
- **State files**: fa keeps `data/fa-state.json` (branch `factory-data`),
  dart `data/dart-state*.json` (branch `factory-state`). A tick log ending
  `═ SM Agent complete — processed` means the tick did work.

## 6. Watch architecture (clean-context discipline)

Keep the coordinating session small: spawn a **sentinel subagent** that owns
the polling loops and remediation, reporting digests every ~30m plus instant
alerts on anomalies/merges; the coordinator relays to the owner, handles
steering, and keeps a scheduled self-reminder loop as the final backstop.
Bash watchdogs (one `gh` call per question, ≥60s between polls) are cheap
insurance but the sentinel owns the contract.
