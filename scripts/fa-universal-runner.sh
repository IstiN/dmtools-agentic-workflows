#!/usr/bin/env bash
# fa-universal-runner.sh — Minimal-dependency, provider-agnostic universal
# runner for `fa` + `dmtools-dart` with DAP channel attachment, single-queue
# catch-up inbox, double-check before exit, and git-branch session persistence.
#
# Supports:
#   - GitHub App auth (FA_GITHUB_APP_ID + FA_GITHUB_APP_PRIVATE_KEY) OR
#     standard keys/tokens (SOURCE_GITHUB_TOKEN, PAT_TOKEN, GITHUB_TOKEN,
#     GITLAB_TOKEN, BITBUCKET_TOKEN).
#   - Direct invocation from GitHub Actions (`fa-universal.yml`), GitLab CI,
#     Bitrise, or any Linux/macOS shell.
#   - Fast parallel binary bootstrap (`fa` + `dmtools-dart` in ~2s).
#   - Automatic synthesis of `~/.dmtools/dmtools.env` from `DMTOOLS_ENV` and
#     any passed integration/AI env vars.
#   - DAP live connection (`DAP_HUB_URL`, `DAP_CLIENT_SECRET`, `DAP_AGENT_NAME`
#     defaults to `SESSION_KEY`).
#   - Catch-up of unread `@fa` comments + post-run double-check before exit.
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g' \
    | cut -c1-63 \
    | sed -E 's/-+$//'
}

b64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# ── 1. Normalize Inputs ───────────────────────────────────────────────────────
PROVIDER="${INPUT_PROVIDER:-${PROVIDER:-github}}"
TARGET_REPO="${INPUT_TARGET_REPO:-${TARGET_REPO:-${GITHUB_REPOSITORY:-}}}"
ISSUE_NUMBER="${INPUT_ISSUE_NUMBER:-${ISSUE_NUMBER:-}}"
COMMENT_ID="${INPUT_COMMENT_ID:-${COMMENT_ID:-}}"
IN_REPLY_TO_ID="${INPUT_IN_REPLY_TO_ID:-${IN_REPLY_TO_ID:-}}"
PROMPT_TEXT="${INPUT_PROMPT:-${PROMPT:-}}"
MENTION_TRIGGER="${FA_TRIGGER_MENTION:-@fa}"

if [ -z "${INPUT_SESSION_KEY:-${SESSION_KEY:-}}" ]; then
  if [ -n "${TARGET_REPO}" ] && [ -n "${ISSUE_NUMBER}" ]; then
    SESSION_KEY="$(slugify "gh-${TARGET_REPO}-${ISSUE_NUMBER}")"
  elif [ -n "${TARGET_REPO}" ]; then
    SESSION_KEY="$(slugify "gh-${TARGET_REPO}-main")"
  else
    SESSION_KEY="fa-universal-default"
  fi
else
  SESSION_KEY="$(slugify "${INPUT_SESSION_KEY:-${SESSION_KEY}}")"
fi
export SESSION_KEY

echo "⚡ fa-universal-runner: provider=${PROVIDER} target_repo=${TARGET_REPO} issue=${ISSUE_NUMBER:-none} session=${SESSION_KEY}"

# ── 2. Mint GitHub App Installation Token (if App credentials provided) ──────
mint_github_app_token() {
  local app_id="${FA_GITHUB_APP_ID:-${APP_ID:-}}"
  local raw_key="${FA_GITHUB_APP_PRIVATE_KEY:-${APP_PRIVATE_KEY:-}}"
  local repo="${1:-}"
  if [ -z "${app_id}" ] || [ -z "${raw_key}" ] || [ -z "${repo}" ]; then
    return 1
  fi

  local key_file
  key_file="$(mktemp)"
  if printf '%s' "${raw_key}" | grep -q "BEGIN "; then
    printf '%s\n' "${raw_key}" > "${key_file}"
  else
    printf '%s' "${raw_key}" | base64 -d > "${key_file}" 2>/dev/null || {
      rm -f "${key_file}"
      return 1
    }
  fi

  local now iat exp header payload unsigned sig jwt
  now="$(date +%s)"
  iat=$((now - 60))
  exp=$((now + 540))
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "${iat}" "${exp}" "${app_id}" | b64url)"
  unsigned="${header}.${payload}"
  sig="$(printf '%s' "${unsigned}" | openssl dgst -sha256 -sign "${key_file}" | b64url)"
  rm -f "${key_file}"
  jwt="${unsigned}.${sig}"

  local inst_id="${FA_GITHUB_APP_INSTALLATION_ID:-}"
  if [ -z "${inst_id}" ]; then
    inst_id="$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${jwt}" \
      "https://api.github.com/repos/${repo}/installation" 2>/dev/null \
      | jq -r '.id // empty' || true)"
  fi
  if [ -z "${inst_id}" ]; then
    return 1
  fi

  local token
  token="$(curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${jwt}" \
    "https://api.github.com/app/installations/${inst_id}/access_tokens" 2>/dev/null \
    | jq -r '.token // empty' || true)"
  if [ -z "${token}" ]; then
    return 1
  fi
  printf '%s' "${token}"
}

# Export paths and start binary downloads IMMEDIATELY (overlapped with GitHub App JWT/token minting!)
export PATH="${HOME}/.local/bin:${HOME}/.dmtools/bin:${PATH}"
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${HOME}/.local/bin" >> "${GITHUB_PATH}"
  echo "${HOME}/.dmtools/bin" >> "${GITHUB_PATH}"
fi

# ── 3. Fast Parallel Binary Install + Shallow Single-Branch Clone ─────────────
install_fa_fast() {
  if command -v fa >/dev/null 2>&1; then
    echo "✅ fa already on PATH: $(command -v fa)"
    return 0
  fi
  local os arch asset tmp url
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    *)      os="linux" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    *)             arch="x64" ;;
  esac
  asset="fa-${os}-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  local ver="${FA_VERSION:-latest}"
  if [ "${ver}" = "latest" ] || [ -z "${ver}" ]; then
    url="https://github.com/IstiN/flutter_agent_harness/releases/latest/download/${asset}"
  else
    url="https://github.com/IstiN/flutter_agent_harness/releases/download/${ver}/${asset}"
  fi
  if ! curl -fsSL "${url}" -o "${tmp}/${asset}" 2>/dev/null; then
    local tag
    tag="$(gh release list --repo IstiN/flutter_agent_harness --limit 10 --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
    if [ -n "${tag}" ]; then
      gh release download "${tag}" --repo IstiN/flutter_agent_harness --pattern "${asset}" --dir "${tmp}" --clobber
    else
      curl -fsSL "https://fa1.dev/install.sh?v=2" | sh
      rm -rf "${tmp}"
      return 0
    fi
  fi
  tar -xzf "${tmp}/${asset}" -C "${tmp}"
  mkdir -p "${HOME}/.local/bin" "${HOME}/.local/lib"
  cp "${tmp}/bundle/bin/fa" "${HOME}/.local/bin/fa"
  chmod +x "${HOME}/.local/bin/fa"
  [ -f "${tmp}/bundle/version.txt" ] && cp "${tmp}/bundle/version.txt" "${HOME}/.local/bin/version.txt"
  [ -d "${tmp}/bundle/lib" ] && cp -R "${tmp}/bundle/lib/." "${HOME}/.local/lib/" 2>/dev/null || true
  rm -rf "${tmp}"
  echo "✅ fa installed: ${HOME}/.local/bin/fa"
}

install_dmtools_fast() {
  if command -v dmtools >/dev/null 2>&1; then
    echo "✅ dmtools already on PATH: $(command -v dmtools)"
    return 0
  fi
  local os arch asset tmp url src install_bin
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    *)      os="linux" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    *)             arch="x64" ;;
  esac
  asset="dmtools-${os}-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  local ver="${DMTOOLS_VERSION:-latest}"
  if [ "${ver}" = "latest" ] || [ -z "${ver}" ]; then
    url="https://github.com/epam/dmtools-dart/releases/latest/download/${asset}"
  else
    case "${ver}" in v*) ;; *) ver="v${ver}" ;; esac
    url="https://github.com/epam/dmtools-dart/releases/download/${ver}/${asset}"
  fi
  curl -fsSL "${url}" -o "${tmp}/${asset}"
  tar -xzf "${tmp}/${asset}" -C "${tmp}"
  src="${tmp}/dmtools"
  [ -d "${src}" ] || src="${tmp}/bundle"
  [ -d "${src}" ] || src="${tmp}"
  install_bin="${HOME}/.dmtools/bin"
  mkdir -p "${install_bin}/native/quickjs"
  cp "${src}/dmtools" "${install_bin}/dmtools.bin"
  chmod +x "${install_bin}/dmtools.bin"
  if [ -f "${src}/native/quickjs/libquickjs_bridge.so" ]; then
    cp "${src}/native/quickjs/libquickjs_bridge.so" "${install_bin}/native/quickjs/libquickjs_bridge.so"
  elif [ -f "${src}/native/quickjs/libquickjs_bridge.dylib" ]; then
    cp "${src}/native/quickjs/libquickjs_bridge.dylib" "${install_bin}/native/quickjs/libquickjs_bridge.dylib"
  fi
  cat > "${install_bin}/dmtools" <<'LAUNCHER'
#!/bin/sh
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$DIR/native/quickjs/libquickjs_bridge.so" ]; then
  export JSR_QUICKJS_LIB="$DIR/native/quickjs/libquickjs_bridge.so"
elif [ -f "$DIR/native/quickjs/libquickjs_bridge.dylib" ]; then
  export JSR_QUICKJS_LIB="$DIR/native/quickjs/libquickjs_bridge.dylib"
fi
exec "$DIR/dmtools.bin" "$@"
LAUNCHER
  chmod +x "${install_bin}/dmtools"
  rm -rf "${tmp}"
  echo "✅ dmtools-dart installed: ${install_bin}/dmtools"
}

install_fa_fast &
PID_FA=$!
install_dmtools_fast &
PID_DMT=$!

APP_TOKEN=""
if [ "${PROVIDER}" = "github" ] && [ -n "${TARGET_REPO}" ]; then
  APP_TOKEN="$(mint_github_app_token "${TARGET_REPO}" || true)"
  if [ -n "${APP_TOKEN}" ]; then
    echo "✅ Minted GitHub App installation token for ${TARGET_REPO}"
    echo "::add-mask::${APP_TOKEN}"
  fi
fi

# Effective GitHub token priority: GitHub App token > SOURCE_GITHUB_TOKEN > PAT_TOKEN > GITHUB_TOKEN
EFFECTIVE_GH_TOKEN="${APP_TOKEN:-${SOURCE_GITHUB_TOKEN:-${PAT_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}}}"
if [ -n "${EFFECTIVE_GH_TOKEN}" ]; then
  export GH_TOKEN="${EFFECTIVE_GH_TOKEN}"
  export GITHUB_TOKEN="${EFFECTIVE_GH_TOKEN}"
  export SOURCE_GITHUB_TOKEN="${EFFECTIVE_GH_TOKEN}"
fi
# Determine workspace before starting parallel jobs so git clone runs concurrently with binary installs
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
NEED_CLONE="false"
if [ "${PROVIDER}" = "github" ] && [ -n "${TARGET_REPO}" ]; then
  CURRENT_REPO="$(git -C "${WORKSPACE}" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#' || true)"
  if [ "${CURRENT_REPO}" != "${TARGET_REPO}" ]; then
    if [ -d "${WORKSPACE}" ] && [ -z "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]; then
      true # reuse empty GITHUB_WORKSPACE
    else
      WORKSPACE="$(mktemp -d)/repo"
    fi
    NEED_CLONE="true"
    export GITHUB_WORKSPACE="${WORKSPACE}"
  fi
fi

clone_target_repo_fast() {
  if [ "${NEED_CLONE}" != "true" ]; then
    return 0
  fi
  local branch="${TARGET_BRANCH:-main}"
  echo "📥 Cloning ${TARGET_REPO} (branch=${branch}, depth=1, single-branch, no-tags)..."
  local clone_url="https://github.com/${TARGET_REPO}.git"
  if [ -n "${EFFECTIVE_GH_TOKEN}" ]; then
    clone_url="https://x-access-token:${EFFECTIVE_GH_TOKEN}@github.com/${TARGET_REPO}.git"
  fi
  if ! git clone --quiet --depth 1 --single-branch --no-tags --branch "${branch}" "${clone_url}" "${WORKSPACE}" 2>/dev/null; then
    git clone --quiet --depth 1 --single-branch --no-tags "${clone_url}" "${WORKSPACE}"
  fi
  local sess_branch="fa-sess/${SESSION_KEY}"
  if git -C "${WORKSPACE}" fetch --quiet --depth 1 --no-tags origin "+refs/heads/${sess_branch}:refs/remotes/origin/${sess_branch}" 2>/dev/null; then
    if [ -n "$(git -C "${WORKSPACE}" ls-tree --name-only "refs/remotes/origin/${sess_branch}" -- .dmtools/fa-sessions 2>/dev/null)" ]; then
      git -C "${WORKSPACE}" checkout -q "refs/remotes/origin/${sess_branch}" -- .dmtools/fa-sessions
      git -C "${WORKSPACE}" restore --staged .dmtools/fa-sessions 2>/dev/null || true
      echo "→ Restored session from ${sess_branch}"
    fi
  fi
}

# Start shallow single-branch git clone AND initial GitHub Issue/comments prefetch concurrently while binary downloads finish!
PREFETCH_ISSUE_FILE="$(mktemp)"
PREFETCH_COMMENTS_FILE="$(mktemp)"
if [ "${PROVIDER}" = "github" ] && [ -n "${TARGET_REPO}" ] && [ -n "${ISSUE_NUMBER}" ]; then
  gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}" 2>/dev/null > "${PREFETCH_ISSUE_FILE}" || echo "{}" > "${PREFETCH_ISSUE_FILE}" &
  PID_PREFETCH_ISS=$!
  gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" --paginate 2>/dev/null > "${PREFETCH_COMMENTS_FILE}" || echo "[]" > "${PREFETCH_COMMENTS_FILE}" &
  PID_PREFETCH_COMM=$!
fi
clone_target_repo_fast &
PID_CLONE=$!

# ── 4. Export Custom Provider Key Slots & Synthesize dmtools.env (runs while downloads finish) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/export-provider-key-slots.sh" ]; then
  if [ -z "${GITHUB_ENV:-}" ]; then
    export GITHUB_ENV="$(mktemp)"
  fi
  bash "${SCRIPT_DIR}/export-provider-key-slots.sh"
  set -a
  # shellcheck source=/dev/null
  [ -f "${GITHUB_ENV}" ] && source "${GITHUB_ENV}" || true
  set +a
fi

# dmtools-dart and fa read environment variables directly from the process environment.
# If a multi-line DMTOOLS_ENV secret is provided, export its KEY=VALUE lines into env.
if [ -n "${DMTOOLS_ENV:-}" ]; then
  while IFS= read -r line; do
    case "${line}" in
      ""|\#*) continue ;;
      *=*) export "${line?}" 2>/dev/null || true ;;
    esac
  done <<< "${DMTOOLS_ENV}"
fi
wait "${PID_FA}"
wait "${PID_DMT}"
wait "${PID_CLONE}"
[ -n "${PID_PREFETCH_ISS:-}" ] && wait "${PID_PREFETCH_ISS}" 2>/dev/null || true
[ -n "${PID_PREFETCH_COMM:-}" ] && wait "${PID_PREFETCH_COMM}" 2>/dev/null || true

# ── 5. Workspace Setup ────────────────────────────────────────────────────────
cd "${WORKSPACE}"

# Configure git credentials on the target checkout (fast inline setup — no submodule walk or API round-trip)
git config user.name "fa[bot]"
git config user.email "fa[bot]@users.noreply.github.com"
if [ -n "${EFFECTIVE_GH_TOKEN}" ]; then
  git config --local --unset-all http.https://github.com/.extraheader 2>/dev/null || true
  git config --local --replace-all credential.helper '' 2>/dev/null || true
  git config --local --replace-all credential.https://github.com.helper '' 2>/dev/null || true
  git config --local --add credential.https://github.com.helper '!f() { [ "$1" = "get" ] || return 0; echo "username=x-access-token"; echo "password=${EFFECTIVE_GH_TOKEN}"; }; f'
fi

# Ensure a valid minimal .fah/config.yaml exists in the workspace when project memory is enabled (default: true)
if [ "${FA_PERSIST_MEMORY:-true}" = "true" ] && [ ! -f "${WORKSPACE}/.fah/config.yaml" ]; then
  mkdir -p "${WORKSPACE}/.fah" "${WORKSPACE}/.fah/memory"
  cat << 'EOF' > "${WORKSPACE}/.fah/config.yaml"
memory:
  projectPath: .fah/memory
EOF
fi

if [ -d "${WORKSPACE}/.git" ]; then
  mkdir -p "${WORKSPACE}/.git/info"
  for pat in "dmtools.env" ".dmtools/" ".dmtools/**" ".fah/bash_jobs/" ".fah/bash_jobs/**" ".fah/.tools/" ".fah/.tools/**" ".fah/trajectories/" ".fah/trajectories/**" ".fah/sessions/" ".fah/sessions/**"; do
    grep -qxF "${pat}" "${WORKSPACE}/.git/info/exclude" 2>/dev/null || echo "${pat}" >> "${WORKSPACE}/.git/info/exclude"
  done
fi

# ── 6. Configure DAP Hub Attachment ───────────────────────────────────────────
export DAP_AGENT_NAME="${DAP_AGENT_NAME:-${SESSION_KEY}}"
if [ -n "${FA_DAP_INVITE:-}" ]; then
  fa dap import "${FA_DAP_INVITE}" 2>/dev/null || true
elif [ -z "${DAP_CLIENT_SECRET:-}" ] && [ -n "${FA_NETWORK_ENROLL_URL:-}" ] && [ -n "${FA_NETWORK_TOKEN:-}" ]; then
  ENROLL_RESP="$(curl -fsSL -X POST "${FA_NETWORK_ENROLL_URL}" \
    -H "Authorization: Bearer ${FA_NETWORK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${DAP_AGENT_NAME}\"}" 2>/dev/null || true)"
  if [ -n "${ENROLL_RESP}" ]; then
    export DAP_CLIENT_SECRET="$(printf '%s' "${ENROLL_RESP}" | jq -r '.clientSecret // empty')"
    export DAP_HUB_URL="${DAP_HUB_URL:-$(printf '%s' "${ENROLL_RESP}" | jq -r '.hubUrl // empty')}"
  fi
fi

# ── 7. Session Restore from `fa-sess/<SESSION_KEY>` Branch ────────────────────
FA_SESS_BRANCH="fa-sess/${SESSION_KEY}"
SESSION_ROOT="${WORKSPACE}/.dmtools/fa-sessions/${SESSION_KEY}"
STATE_FILE="${SESSION_ROOT}/.fa-universal-state.json"
mkdir -p "${SESSION_ROOT}"

if [ "${NEED_CLONE}" != "true" ]; then
  if git fetch --quiet --depth 1 --no-tags origin "+refs/heads/${FA_SESS_BRANCH}:refs/remotes/origin/${FA_SESS_BRANCH}" 2>/dev/null; then
    if [ -n "$(git ls-tree --name-only "refs/remotes/origin/${FA_SESS_BRANCH}" -- .dmtools/fa-sessions 2>/dev/null)" ]; then
      git checkout -q "refs/remotes/origin/${FA_SESS_BRANCH}" -- .dmtools/fa-sessions
      git restore --staged .dmtools/fa-sessions 2>/dev/null || true
      echo "→ Restored session from ${FA_SESS_BRANCH}"
    fi
  fi
fi
LAST_COMMENT_ID="0"
if [ -f "${STATE_FILE}" ]; then
  LAST_COMMENT_ID="$(jq -r '.lastProcessedCommentId // "0"' "${STATE_FILE}" 2>/dev/null || echo "0")"
fi

# ── 8. Catch-Up Inbox & Single-Queue Processing Loop ──────────────────────────
# Collects any unprocessed @fa comments on the GitHub Issue/PR since LAST_COMMENT_ID.
fetch_unprocessed_github_comments() {
  local repo="$1"
  local issue="$2"
  local since_id="${3:-0}"
  if [ -z "${repo}" ] || [ -z "${issue}" ] || [ "${PROVIDER}" != "github" ]; then
    return 0
  fi
  if [ -n "${PREFETCH_COMMENTS_FILE:-}" ] && [ -s "${PREFETCH_COMMENTS_FILE}" ]; then
    jq -c --argjson since "${since_id}" --arg trig "${MENTION_TRIGGER}" '
      .[]
      | select(.id > $since)
      | select((.user.type // "") != "Bot")
      | select((.user.login // "") | test("\\[bot\\]$") | not)
      | select((.body // "") | ascii_downcase | contains($trig | ascii_downcase))
      | {id: .id, author: .user.login, created_at: .created_at, body: .body, url: .html_url}
    ' "${PREFETCH_COMMENTS_FILE}" 2>/dev/null || true
    rm -f "${PREFETCH_COMMENTS_FILE}"
    PREFETCH_COMMENTS_FILE=""
    return 0
  fi
  gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate 2>/dev/null \
    | jq -c --argjson since "${since_id}" --arg trig "${MENTION_TRIGGER}" '
      .[]
      | select(.id > $since)
      | select((.user.type // "") != "Bot")
      | select((.user.login // "") | test("\\[bot\\]$") | not)
      | select((.body // "") | ascii_downcase | contains($trig | ascii_downcase))
      | {id: .id, author: .user.login, created_at: .created_at, body: .body, url: .html_url}
    ' || true
}

build_turn_prompt() {
  local out_file="$1"
  local new_max_id="${LAST_COMMENT_ID}"

  if [ "${PROVIDER}" = "github" ] && [ -n "${TARGET_REPO}" ] && [ -n "${ISSUE_NUMBER}" ]; then
    local issue_json title body state is_pr comments_jsonl
    if [ -n "${PREFETCH_ISSUE_FILE:-}" ] && [ -s "${PREFETCH_ISSUE_FILE}" ]; then
      issue_json="$(cat "${PREFETCH_ISSUE_FILE}")"
      rm -f "${PREFETCH_ISSUE_FILE}"
      PREFETCH_ISSUE_FILE=""
      comments_jsonl="$(fetch_unprocessed_github_comments "${TARGET_REPO}" "${ISSUE_NUMBER}" "${LAST_COMMENT_ID}")"
    else
      local issue_tmp comments_tmp
      issue_tmp="$(mktemp)"
      comments_tmp="$(mktemp)"
      fetch_unprocessed_github_comments "${TARGET_REPO}" "${ISSUE_NUMBER}" "${LAST_COMMENT_ID}" > "${comments_tmp}" &
      local pid_comm=$!
      gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}" 2>/dev/null > "${issue_tmp}" || echo "{}" > "${issue_tmp}" &
      local pid_iss=$!
      wait "${pid_comm}" || true
      wait "${pid_iss}" || true
      comments_jsonl="$(cat "${comments_tmp}")"
      issue_json="$(cat "${issue_tmp}")"
      rm -f "${comments_tmp}" "${issue_tmp}"
    fi

    if [ -z "${comments_jsonl}" ] && [ -n "${COMMENT_ID}" ] && [ "${COMMENT_ID}" -le "${LAST_COMMENT_ID}" ] 2>/dev/null; then
      return 1
    fi

    title="$(printf '%s' "${issue_json}" | jq -r '.title // ""')"
    body="$(printf '%s' "${issue_json}" | jq -r '.body // ""')"
    state="$(printf '%s' "${issue_json}" | jq -r '.state // "open"')"
    is_pr="$(printf '%s' "${issue_json}" | jq -r 'if .pull_request != null then "Pull Request" else "Issue" end')"
    {
      echo "# Context: ${TARGET_REPO} ${is_pr} #${ISSUE_NUMBER} (${state})"
      echo "**Title:** ${title}"
      echo ""
      echo "## Description"
      echo "${body}"
      echo ""
      if [ -n "${comments_jsonl}" ]; then
        echo "## New Mention Messages to Process"
        while IFS= read -r item; do
          [ -z "${item}" ] && continue
          local cid cauthor cdate cbody
          cid="$(printf '%s' "${item}" | jq -r '.id')"
          cauthor="$(printf '%s' "${item}" | jq -r '.author')"
          cdate="$(printf '%s' "${item}" | jq -r '.created_at')"
          cbody="$(printf '%s' "${item}" | jq -r '.body')"
          echo "### Comment #${cid} by @${cauthor} (${cdate})"
          echo "${cbody}"
          echo ""
          if [ "${cid}" -gt "${new_max_id}" ] 2>/dev/null; then
            new_max_id="${cid}"
          fi
        done <<< "${comments_jsonl}"
      elif [ -n "${PROMPT_TEXT}" ]; then
        echo "## Incoming Instruction"
        echo "${PROMPT_TEXT}"
        echo ""
        PROMPT_TEXT="" # consume once so the post-turn double-check only runs if new comments arrive
        if [ -n "${COMMENT_ID}" ] && [ "${COMMENT_ID}" -gt "${new_max_id}" ] 2>/dev/null; then
          new_max_id="${COMMENT_ID}"
        fi
      else
        return 1
      fi
      echo "---"
      echo "Respond directly and concisely. If you make code changes or open a PR, summarize what you did."
    } > "${out_file}"

    NEXT_COMMENT_ID="${new_max_id}"
    return 0
  fi

  # Non-GitHub-Issue or direct prompt mode
  if [ -n "${PROMPT_TEXT}" ]; then
    printf '%s\n' "${PROMPT_TEXT}" > "${out_file}"
    PROMPT_TEXT="" # consume once
    NEXT_COMMENT_ID="${COMMENT_ID:-${LAST_COMMENT_ID}}"
    return 0
  fi

  return 1
}

run_fa_turn() {
  local prompt_file="$1"
  local reply_file="$2"
  local cmd=(fa --session "${SESSION_KEY}" --session-root "${SESSION_ROOT}" --prompt-file "${prompt_file}")

  local prov="${INPUT_PROVIDER_NAME:-}"
  local mod="${INPUT_MODEL:-}"
  local base_url="${INPUT_BASE_URL:-}"

  # If FA_PROVIDER_TYPE + FA_PROVIDER_CONFIG are not already preconfigured,
  # auto-configure FA_PROVIDER_* from INPUT_PROVIDER_NAME or available API keys.
  if [ -z "${FA_PROVIDER_TYPE:-}" ] || [ -z "${FA_PROVIDER_CONFIG:-}" ]; then
    if [ -z "${prov}" ]; then
      if [ -n "${KIMI_API_KEY:-}" ]; then
        prov="kimi"
        mod="${mod:-kimi-for-coding}"
      elif [ -n "${ZAI_API_KEY:-}" ]; then
        prov="zai"
        mod="${mod:-glm-4.5}"
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        prov="anthropic"
        mod="${mod:-claude-sonnet-4-5}"
      elif [ -n "${GEMINI_API_KEY:-}" ]; then
        prov="google"
        mod="${mod:-gemini-2.5-pro}"
      elif [ -n "${OPENROUTER_API_KEY:-}" ]; then
        prov="openrouter"
        mod="${mod:-anthropic/claude-sonnet-4}"
      elif [ -n "${OPENAI_API_KEY:-}" ]; then
        prov="openai"
        mod="${mod:-gpt-4o}"
      fi
    fi

    case "${prov}" in
      kimi)
        export FA_PROVIDER_TYPE="kimi"
        export FA_PROVIDER_CONFIG="$(jq -nc \
          --arg base "${base_url:-https://api.kimi.com/coding/v1}" \
          --arg model "${mod:-kimi-for-coding}" \
          '{baseUrl: $base, model: $model, apiKeyEnvVar: "KIMI_API_KEY", input: ["text", "image"]}')"
        export FA_PROVIDERS_QUEUE="$(jq -nc \
          --arg base "${base_url:-https://api.kimi.com/coding/v1}" \
          --arg model "${mod:-kimi-for-coding}" \
          '[{provider_type: "openai-completions", provider_config: {baseUrl: $base, model: $model, apiKeyEnv: "KIMI_API_KEY", input: ["text", "image"]}}]')"
        ;;
      zai)
        export FA_PROVIDER_TYPE="zai"
        export FA_PROVIDER_CONFIG="$(jq -nc \
          --arg base "${base_url:-https://api.z.ai/api/coding/paas/v4}" \
          --arg model "${mod:-glm-4.5}" \
          '{baseUrl: $base, model: $model, apiKeyEnvVar: "ZAI_API_KEY", input: ["text", "image"]}')"
        export FA_PROVIDERS_QUEUE="$(jq -nc \
          --arg base "${base_url:-https://api.z.ai/api/coding/paas/v4}" \
          --arg model "${mod:-glm-4.5}" \
          '[{provider_type: "zai", provider_config: {baseUrl: $base, model: $model, apiKeyEnv: "ZAI_API_KEY", input: ["text", "image"]}}]')"
        ;;
      anthropic)
        export FA_PROVIDER_TYPE="anthropic"
        export FA_PROVIDER_CONFIG="$(jq -nc \
          --arg base "${base_url:-https://api.anthropic.com}" \
          --arg model "${mod:-claude-sonnet-4-5}" \
          '{baseUrl: $base, model: $model, apiKeyEnvVar: "ANTHROPIC_API_KEY", input: ["text", "image"]}')"
        export FA_PROVIDERS_QUEUE="$(jq -nc \
          --arg base "${base_url:-https://api.anthropic.com}" \
          --arg model "${mod:-claude-sonnet-4-5}" \
          '[{provider_type: "anthropic", provider_config: {baseUrl: $base, model: $model, apiKeyEnv: "ANTHROPIC_API_KEY", input: ["text", "image"]}}]')"
        ;;
      google|gemini)
        export FA_PROVIDER_TYPE="google"
        export FA_PROVIDER_CONFIG="$(jq -nc \
          --arg base "${base_url:-https://generativelanguage.googleapis.com/v1beta}" \
          --arg model "${mod:-gemini-2.5-pro}" \
          '{baseUrl: $base, model: $model, apiKeyEnvVar: "GEMINI_API_KEY", input: ["text", "image"]}')"
        export FA_PROVIDERS_QUEUE="$(jq -nc \
          --arg base "${base_url:-https://generativelanguage.googleapis.com/v1beta}" \
          --arg model "${mod:-gemini-2.5-pro}" \
          '[{provider_type: "google", provider_config: {baseUrl: $base, model: $model, apiKeyEnv: "GEMINI_API_KEY", input: ["text", "image"]}}]')"
        ;;
      openrouter)
        export FA_PROVIDER_TYPE="openrouter"
        export FA_PROVIDER_CONFIG="$(jq -nc \
          --arg base "${base_url:-https://openrouter.ai/api/v1}" \
          --arg model "${mod:-anthropic/claude-sonnet-4}" \
          '{baseUrl: $base, model: $model, apiKeyEnvVar: "OPENROUTER_API_KEY", input: ["text", "image"]}')"
        export FA_PROVIDERS_QUEUE="$(jq -nc \
          --arg base "${base_url:-https://openrouter.ai/api/v1}" \
          --arg model "${mod:-anthropic/claude-sonnet-4}" \
          '[{provider_type: "openai-completions", provider_config: {baseUrl: $base, model: $model, apiKeyEnv: "OPENROUTER_API_KEY", input: ["text", "image"]}}]')"
        ;;
      openai|openai-completions)
        export FA_PROVIDER_TYPE="openai"
        export FA_PROVIDER_CONFIG="$(jq -nc \
          --arg base "${base_url:-https://api.openai.com/v1}" \
          --arg model "${mod:-gpt-4o}" \
          '{baseUrl: $base, model: $model, apiKeyEnvVar: "OPENAI_API_KEY", input: ["text", "image"]}')"
        export FA_PROVIDERS_QUEUE="$(jq -nc \
          --arg base "${base_url:-https://api.openai.com/v1}" \
          --arg model "${mod:-gpt-4o}" \
          '[{provider_type: "openai-completions", provider_config: {baseUrl: $base, model: $model, apiKeyEnv: "OPENAI_API_KEY", input: ["text", "image"]}}]')"
        ;;
      *)
        if [ -n "${prov}" ]; then
          cmd+=(--provider "${prov}")
        fi
        if [ -n "${base_url}" ]; then
          cmd+=(--base-url "${base_url}")
        fi
        if [ -n "${mod}" ]; then
          cmd+=(--model "${mod}")
        fi
        ;;
    esac
  fi

  echo "🚀 Executing: ${cmd[*]} (FA_PROVIDER_TYPE=${FA_PROVIDER_TYPE:-})"
  "${cmd[@]}" | tee "${reply_file}"
}

post_scm_reply() {
  local reply_file="$1"
  local thread_reply_id="${2:-${IN_REPLY_TO_ID:-}}"
  if [ "${POST_REPLY_TO_ISSUE:-true}" != "true" ]; then
    return 0
  fi
  if [ ! -s "${reply_file}" ]; then
    return 0
  fi

  if [ "${PROVIDER}" = "github" ] && [ -n "${TARGET_REPO}" ] && [ -n "${ISSUE_NUMBER}" ]; then
    local owner repo
    owner="${TARGET_REPO%%/*}"
    repo="${TARGET_REPO#*/}"

    # Prefer dmtools (dmtools-dart / java) CLI tools if available
    if command -v dmtools >/dev/null 2>&1; then
      # 1. PR review thread reply (inline code comment thread)
      if [ -n "${thread_reply_id}" ] && [ "${thread_reply_id}" != "0" ] && [ "${thread_reply_id}" != "null" ]; then
        local req_payload
        req_payload="$(jq -nc \
          --arg ws "${owner}" \
          --arg r "${repo}" \
          --arg pr "${ISSUE_NUMBER}" \
          --arg thread "${thread_reply_id}" \
          --rawfile text "${reply_file}" \
          '{workspace: $ws, repository: $r, pullRequestId: $pr, inReplyToId: $thread, text: $text}')"
        local resp
        resp="$(dmtools github_reply_to_pr_thread --data "${req_payload}" 2>&1 || true)"
        if printf '%s' "${resp}" | grep -q '"id"\|"body"'; then
          echo "💬 Posted reply to PR review thread #${thread_reply_id} on ${TARGET_REPO}#${ISSUE_NUMBER} via dmtools"
          return 0
        else
          echo "::warning::dmtools github_reply_to_pr_thread failed (${resp}), falling back to gh api"
        fi
      fi

      # 2. General Issue / PR comment via dmtools
      local req_payload
      req_payload="$(jq -nc \
        --arg ws "${owner}" \
        --arg r "${repo}" \
        --arg pr "${ISSUE_NUMBER}" \
        --rawfile body "${reply_file}" \
        '{workspace: $ws, repository: $r, pullRequestId: $pr, body: $body}')"
      local resp
      resp="$(dmtools github_create_comment --data "${req_payload}" 2>&1 || true)"
      if printf '%s' "${resp}" | grep -q '"id"\|"body"'; then
        echo "💬 Posted agent response to ${TARGET_REPO}#${ISSUE_NUMBER} via dmtools"
        return 0
      else
        echo "::warning::dmtools github_create_comment failed (${resp}), falling back to gh api"
      fi
    fi

    # Fallback to gh api if dmtools is not on PATH or call failed
    if [ -n "${thread_reply_id}" ] && [ "${thread_reply_id}" != "0" ] && [ "${thread_reply_id}" != "null" ]; then
      local gh_thread_payload
      gh_thread_payload="$(jq -nc \
        --arg in_reply_to "${thread_reply_id}" \
        --rawfile body "${reply_file}" \
        '{in_reply_to: ($in_reply_to | tonumber), body: $body}')"
      if gh api "repos/${TARGET_REPO}/pulls/${ISSUE_NUMBER}/comments" \
        --input - <<< "${gh_thread_payload}" >/dev/null 2>&1; then
        echo "💬 Posted reply to PR review thread #${thread_reply_id} on ${TARGET_REPO}#${ISSUE_NUMBER} via gh api"
        return 0
      fi
    fi

    gh api "repos/${TARGET_REPO}/issues/${ISSUE_NUMBER}/comments" \
      -X POST -F "body=@${reply_file}" >/dev/null 2>&1 \
      && echo "💬 Posted agent response to ${TARGET_REPO}#${ISSUE_NUMBER} via gh api" \
      || echo "::warning::Failed to post comment to ${TARGET_REPO}#${ISSUE_NUMBER}"
  fi
}

TURN=0
MAX_TURNS="${FA_UNIVERSAL_MAX_CATCHUP_TURNS:-5}"
NEXT_COMMENT_ID="${LAST_COMMENT_ID}"

while [ "${TURN}" -lt "${MAX_TURNS}" ]; do
  PROMPT_FILE="$(mktemp)"
  REPLY_FILE="$(mktemp)"
  if ! build_turn_prompt "${PROMPT_FILE}"; then
    rm -f "${PROMPT_FILE}" "${REPLY_FILE}"
    if [ "${TURN}" -eq 0 ]; then
      echo "✅ Nothing new to process (already caught up at comment ${LAST_COMMENT_ID})."
    else
      echo "✅ Inbox drained after ${TURN} turn(s)."
    fi
    break
  fi

  TURN=$((TURN + 1))
  echo "🔄 Turn ${TURN}: processing up to comment ID ${NEXT_COMMENT_ID}..."
  run_fa_turn "${PROMPT_FILE}" "${REPLY_FILE}"
  post_scm_reply "${REPLY_FILE}"
  rm -f "${PROMPT_FILE}" "${REPLY_FILE}"

  LAST_COMMENT_ID="${NEXT_COMMENT_ID}"
  printf '{"lastProcessedCommentId":%s,"updatedAt":"%s","sessionKey":"%s"}\n' \
    "${LAST_COMMENT_ID:-0}" "$(date -u +%FT%TZ)" "${SESSION_KEY}" > "${STATE_FILE}"

  # If not a GitHub issue thread, one turn is enough
  if [ -z "${ISSUE_NUMBER}" ] || [ "${PROVIDER}" != "github" ]; then
    break
  fi
done

# ── 9. Persist Session to `fa-sess/<SESSION_KEY>` Branch ──────────────────────
persist_session() {
  if [ "${TURN}" -eq 0 ]; then
    return 0
  fi
  if [ ! -d "${WORKSPACE}/.dmtools/fa-sessions" ] || \
     [ -z "$(find "${WORKSPACE}/.dmtools/fa-sessions" -type f -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  local snap orig_branch
  snap="$(mktemp -d)"
  cp -a "${WORKSPACE}/.dmtools/fa-sessions" "${snap}/"
  orig_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

  git config user.name "fa[bot]"
  git config user.email "fa[bot]@users.noreply.github.com"

  # Commit and push any repo changes (memory in .fah/memory, .fah/config.yaml, scripts, or workspace files)
  # before switching to the orphan session branch.
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "${orig_branch}")"
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -A
    # Never stage transient session or env files onto the code/memory branch
    git reset -q HEAD -- dmtools.env .dmtools .fah/bash_jobs .fah/.tools .fah/sessions .fah/trajectories 2>/dev/null || true
    if [ "${FA_PERSIST_MEMORY:-true}" = "false" ]; then
      git reset -q HEAD -- .fah/memory .fah/config.yaml 2>/dev/null || true
    fi
    if ! git diff --cached --quiet; then
      git commit -m "fa(${SESSION_KEY}): update repo memory/files [skip ci]" 2>/dev/null || true
      if ! git push origin "HEAD:${current_branch}" 2>/dev/null; then
        git pull --rebase origin "${current_branch}" 2>/dev/null || true
        git push origin "HEAD:${current_branch}" 2>/dev/null \
          && echo "🧠 Repo changes (.fah/memory, scripts, config) pushed to ${current_branch}" \
          || echo "::warning::Could not push repo changes to ${current_branch} (protected or diverged)"
      else
        echo "🧠 Repo changes (.fah/memory, scripts, config) pushed to ${current_branch}"
      fi
    fi
  fi

  git switch --orphan "${FA_SESS_BRANCH}" 2>/dev/null || git switch -C "${FA_SESS_BRANCH}"
  rm -rf .dmtools/fa-sessions
  mkdir -p .dmtools
  cp -a "${snap}/fa-sessions" .dmtools/
  rm -rf "${snap}"
  git add -f .dmtools/fa-sessions
  if ! git diff --cached --quiet; then
    git commit -m "fa session: ${SESSION_KEY} (comment ${LAST_COMMENT_ID}) [skip ci]"
    git push origin "HEAD:${FA_SESS_BRANCH}" --force 2>/dev/null \
      && echo "💾 Session persisted to ${FA_SESS_BRANCH}" \
      || echo "::warning::Failed to push session branch ${FA_SESS_BRANCH}"
  fi
  git checkout -f "${orig_branch}" 2>/dev/null || true
}

persist_session
