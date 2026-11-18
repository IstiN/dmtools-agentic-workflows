# AGENTS.md — rules for working in dmtools-agentic-workflows

This repo is the **shared CI/CD workflow home** of the dmtools agent
ecosystem: today the GitHub Actions machine-loop factory (the `factory-*.yml`
reusable workflows), tomorrow the GitLab pipeline equivalents in the same
repo. Read `README.md` first — it defines the freeze contract and the
consume/add guides.

## Purpose (owner mandate, 2026-10-01)

- **Only shared workflows live here.** GitHub workflows under
  `.github/workflows/` now; GitLab pipelines under `gitlab/` when they
  arrive. No scripts, no prompts, no examples, no repo-local state —
  anything a workflow needs at run time comes from the CALLER's repo, the
  dmtools-agents release, or the dmtools-dart CLI release.
- Target repos carry thin stubs (triggers + one pinned `uses:` call); this
  repo carries everything below the event boundary.

## 1. Non-negotiable rules

1. **Callers pin by immutable SHA; we never break a pinned surface.** Any
   change to a workflow file here is a contract change for every caller.
   Treat edits like API breaks: bump-worthy only, small, and announced in
   the commit/PR so callers can update their pin + guard constant in the
   same motion.
2. **Versions never live in these files.** Agent code comes from
   dmtools-agents releases (`vars.AGENTS_VERSION`), the CLI from
   dmtools-dart releases (`vars.DMTOOLS_VERSION`). Hardcoding a version or a
   release tag here violates the freeze model. `latest` resolves at run
   time via the resolver steps; concrete tags pass through untouched.
3. **`secrets` and `vars` resolve from the CALLER.** These workflows run as
   reusable (`workflow_call`) units; `vars.*`/`secrets.*` referenced here
   come from the calling repository. Never assume this repo's settings.
4. **Concurrency is callee-owned here; caller stubs stay concurrency-free.**
   A reusable workflow's `concurrency` IS evaluated — in the caller's
   context (live bisect 2026-09-22: probes D–G green without any callee
   block, H red on a caller/callee same-name collision, H1 green after
   rename). What deadlocks a reusable call ("pending, 0 jobs") is a
   caller declaring the SAME group name the callee holds. So the factory
   workflow that needs single-flight owns its group here — scoped per
   target repo via `${{ github.repository }}`, per head via
   `${{ github.sha }}` (template: the `CONSUMERS:` note in
   `factory-sm-kicker.yml`), or a bare literal (`machine-sm` in
   `factory-sm.yml` — no template needed: GitHub namespaces concurrency
   groups per repository, so a bare name can never collide across
   repos) — and caller stubs must NOT declare a same-name group for
   factory-owned legs.
5. **Engine pin ≠ factory pin.** The `uses:` pin (this repo) and the
   `factory_ref` input (dmtools-agents SHA) are two independent pins —
   guards in caller repos assert both; never conflate them.
6. **Triggers stay repo-side.** `on:` blocks cannot be parameterized; the
   stub owns events (issues/cron/workflow_run on the caller's CI name) and
   the factory owns everything after the event.

## 2. Working in this repo

- There is no CI here (the repo IS workflows; a PR changes contract
   surface). Reviews are manual: read the diff against every caller input
   you touch.
- Merges to main = a new adoptable SHA. Callers move on their own
   schedule — old SHAs keep working forever (git history is the ABI).
- When adding a workflow: follow the house pattern (`workflow_call` inputs
   with safe defaults, repo-specific names parameterized, no versions, no
   concurrency). Document the caller stub shape in `README.md`.
- GitLab pipelines (future): same freeze contract, `gitlab/` namespace,
   stub/pin discipline unchanged — the contract is CI-system-agnostic.
