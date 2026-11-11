# Development mode (`developmentMode`) — factory pass-through & version path

> Context: dmtools-agents epic #1440 (configurable development modes: `default | plan | adaptive`). This document is the **workflows-repo side of record** (IstiN/dmtools-agentic-workflows#92): how the new leg-config field reaches dev legs, what bumps at rollout, and the checked-clean sweep.

## What the field is

`params.customParams.developmentMode` ∈ `default | plan | adaptive` (missing/invalid ⇒ `default`, zero behavior change) — implemented engine-side (dmtools-agents#1435, merged 2026-11-11 via #1441). Optional tuning lives under `customParams.developmentModeConfig` (plan/adaptive/spawn slices).

## Pass-through mechanics (AC1)

The factory workflows never inspect, assemble, or filter leg-config **content**. The config resolution selects a **file** and hands its path to the engine:

1. `factory-teammate.yml` → step *"Resolve parent config"* (extracted: `scripts/resolve-parent-config.sh`):
   - unpacked pack launch.json wins: `~/.dmtools/packs/<agent>-*/launch.json` (highest `-V`);
   - fallback: `<FACTORY_ROOT>/<agent>.json` or `<FACTORY_ROOT>/configs/<agent>.json`.
2. `AI_TEAMMATE_CONFIG_FILE=<path>` rides `GITHUB_ENV` → the engine (js) reads the file, validates `developmentMode`, resolves the mode, logs `developmentMode=<resolved>`.

The script copies a **path**, not content — any new `customParams.*` field passes through untouched. Verified with a fixture pack config carrying `customParams.developmentMode: "plan"`: `resolve-parent-config.sh` selects it unchanged — smoke transcript in [Smoke evidence](#smoke-evidence-ac1); regression case `dev-mode-field` added to `scripts/ab_test/resolve-parent-config.scenario.sh`. Engine-side resolution was exercised end-to-end by #1435's own leg (ran through `ai-teammate.yml` → `factory-teammate.yml@main`; pack resolved via `AGENTS_VERSION=latest` → the `agents-rel-*` release that carried the merged resolver).

## Version path (AC2) — what bumps at rollout

Resolution chain for the agents pack a leg runs against:

```
AGENTS_VERSION (repo variable, awf#25 documented knob)
   ├─ pinned to concrete agents-rel-* tag → that tag WINS (setup pack + runtime pack registry)
   └─ 'latest' (default) → DMTOOLS_PACK_REGISTRY (repo variable; if unset/empty → newest agents-rel-* tag via `gh release list`, scripts/fetch-factory-setup.sh)
          → fetch-factory-setup.sh: factory-setup-*.zip from dmtools-agents releases
          → unpack → ~/.dmtools/packs/<agent>-<version>/ → launch.json wins (resolve-parent-config.sh)
```

Who bumps what at rollout:

| Repo | How dev-mode features arrive | Action needed |
|---|---|---|
| **dmtools-agents** | resolves packs **like every consumer**: `AGENTS_VERSION=latest` (repo variable) → newest `agents-rel-*` release | nothing while `AGENTS_VERSION=latest` — merged features reach legs on the next release (`agents-rel-20261111-095205` already carries the #1435 resolver; release 09:52Z, merge 09:49Z). **If `AGENTS_VERSION` is ever pinned, that pin is the bump point** |
| consumer repo riding `latest` | every `agents-rel-*` release carries new engine features | nothing; features arrive on next release |
| consumer repo with pinned `AGENTS_VERSION` | only what the pinned tag carries | **bump `AGENTS_VERSION`** to a tag ≥ the feature's release before relying on the field |

Historical note: the `factory_ref` era ended in this repo's #48 (2026-10-17) — the input was removed as an unread no-op and the factory resolves the engine from dmtools-agents releases (`vars`, `latest` default). The engine stub `ai-teammate.yml` still carries the stale self-hosted header text; dmtools-agents#931 swept the caller. Do not cite the stub header as wiring evidence.

The "forgotten bump" failure mode (pinned consumer silently runs pre-feature engine — cf. dmtools-agents#1283) is covered for the engine repo itself only while `AGENTS_VERSION=latest` — the pin knob is unset-by-default there; pinning it would introduce exactly this failure mode.

## Sweep result (AC3)

`developmentMode` touches only leg-config content; a sweep of every wrapper file found **no pass-through risk**:

- `kit/git-push-guard.sh`, `kit/install-source-git-credentials.sh` — git plumbing, content-agnostic.
- `scripts/resolve-parent-config.sh` — file selection only (AC1 above).
- `scripts/resolve-dmtools-version.sh` — dmtools CLI version (`DMTOOLS_VERSION`), orthogonal to leg config.
- `scripts/fetch-factory-setup.sh` — pack download/unpack (AC2 chain), content-agnostic.
- `scripts/fa-universal-runner.sh` + `fa-universal.yml` — pass `FA_PROVIDER_CONFIG` (provider settings) only.
- `scripts/mark-job-*.sh`, `stall-capture.sh`, `dmtools-selfheal.sh`, `export-provider-key-slots.sh`, `seed-git-excludes.sh`, `ab_test`, `sm_merge_guard*.py` — job/lifecycle plumbing, content-agnostic.
- `scripts/install-dmtools-cli.sh`, `scripts/install-fa-cli.sh` — CLI installers, content-agnostic.
- `scripts/sm_merge_guard_selftest.sh` — self-test plumbing for the merge guard, content-agnostic.
- `scripts/teammate-dispatch-gate.sh`, `scripts/trace-git-credentials.sh`, `scripts/verify-prerequisites.sh`, `scripts/write-input-issue.sh`, `scripts/write-input-pr.sh` — dispatch gating / credential tracing / prerequisite checks / input writers; none read or transform leg-config content.
- `.github/workflows/factory-*.yml` — resolve steps pass file paths + env; `factory-sm.yml`/`factory-merge.yml` assemble `jobParams` override JSON, but that is job-params only — leg-config content (`customParams`) passes path-only, never filtered.

**Result: no wrapper change required for any developmentMode slice (plan / adaptive / spawn).** Future leg-config fields follow the same path — this document is the reference to check instead of re-litigating.

## Related
- Epic: dmtools-agents#1440 · knob #1435 · plan-mode #1436 · adaptive #1437 · rollout #1438 (references this doc).
- Pin knob semantics: awf#25 · config acquisition rollout: awf#91.
## Smoke evidence (AC1)

```
fixture: ~/.dmtools/packs/ai_teammate-9.9.9/launch.json
         {"params":{"customParams":{"developmentMode":"plan","developmentModeConfig":{"adaptive":{"planIfBodyTokensAtLeast":800}}}}}

$ LEGACY_CONFIG=ai_teammate bash -e scripts/resolve-parent-config.sh
→ pack launch.json wins: ~/.dmtools/packs/ai_teammate-9.9.9/launch.json
$ GITHUB_ENV
AI_TEAMMATE_CONFIG_FILE=/tmp/…/packs/ai_teammate-9.9.9/launch.json
content hash before == after (file untouched); developmentMode survives: plan

fallback (pack dir removed):
→ no unpacked ai_teammate pack launch.json — legacy config: <FACTORY_ROOT>/configs/ai_teammate.json
AI_TEAMMATE_CONFIG_FILE=<FACTORY_ROOT>/configs/ai_teammate.json
```

Pass-through regression evidence: the smoke transcript above (both resolution paths, content-hash proof); the A/B harness (`scripts/ab_test/resolve-parent-config.scenario.sh`) continues to guard resolver behavior byte-for-byte against the pre-de-bloat snapshot.
