#!/usr/bin/env bash
# Extracted byte-for-byte from .github/workflows/factory-teammate.yml
# @ a4cd62f (step: Trace git credential stack (push-time evidence)) — stage-2 de-bloat.
# Behavior contract: identical. Invoke with `bash -e` (the GH runner default
# shell for inline `run:`); env block stays on the workflow step.
  mkdir -p .dmtools
  echo "── credential.helper — all scopes, with origins ──"
  git config --show-origin --get-all credential.helper || true
  git config --show-origin --get-all credential.https://github.com.helper || true
  echo "── http.https://github.com/.extraheader (must be empty — App token purged) ──"
  # Redact the VALUE (gh-63 review threads 11/12): on a leftover this
  # dump prints AUTHORIZATION: basic <base64(App token)> — GitHub's
  # log masking matches the raw token string, not its base64 form.
  # git 2.x prints "<origin>\t<value>" (--show-origin --get-all has
  # NO key= prefix), so redact everything after the first TAB — a
  # sed on '=' alone would only trim the base64 padding. The origin
  # (file/scope) stays visible; a tab-less line is fully redacted.
  git config --show-origin --get-all http.https://github.com/.extraheader | sed -E 's/^([^\t]*\t).*/\1<redacted>/; t; s/.+/<redacted> (unexpected line without origin)/' || true
  if git config --get-all http.https://github.com/.extraheader | grep -q .; then
    echo "::error::App-token extraheader still present after purge — pushes would authenticate as github-actions[bot]"
    exit 1
  fi
  echo "── submodule extraheaders (must be empty — App token purged there too) ──"
  # checkout arms every submodule's local config with the same token;
  # a push made from inside agents/ must not fall back to it (gh-63).
  # The probe echoes a LEFTOVER marker line only when a config is
  # still armed, so "no submodules" and "all clean" stay quiet.
  # The marker names the submodule but NEVER the header value: it is
  # AUTHORIZATION: basic <base64(App token)>, decodable and NOT masked
  # by GitHub log redaction (gh-63 review threads 11/12).
  sub_leftovers="$(git submodule foreach --quiet --recursive \
    'c="$(git config --get-all http.https://github.com/.extraheader || true)"; [ -z "$c" ] || echo "LEFTOVER ${sm_path}: <redacted>"' \
    || true)"
  if [ -n "$sub_leftovers" ]; then
    echo "::error::App-token extraheader still present in a submodule config after purge — pushes from inside the submodule would authenticate as github-actions[bot]"
    printf '%s\n' "$sub_leftovers"
    exit 1
  fi
  echo "── commit identity ──"
  git var GIT_AUTHOR_IDENT
  git var GIT_COMMITTER_IDENT
  echo "── dry-run: credential a github.com push would use ──"
  # Capture first, then assert: with GIT_ASKPASS=echo `git credential
  # fill` exits 0 even when NO helper answered (echo prints its prompt
  # back, git accepts it as a bogus credential) — only the
  # SOURCE helper's username proves the SOURCE credential wins.
  # CRED_HELPER_CONTEXT tags the helper's log line so this dry-run
  # stays distinguishable from real pushes in the evidence log.
  out="$(printf 'protocol=https\nhost=github.com\n' | CRED_HELPER_CONTEXT=trace-dry-run GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=echo git credential fill 2>&1)" || true
  if printf '%s\n' "$out" | grep -q '^username=x-access-token$'; then
    echo "$out" | sed -E 's/^password=.+/password=<redacted — served by the SOURCE_GITHUB_TOKEN helper>/'
  else
    echo "::error::dry-run credential was NOT served by the SOURCE_GITHUB_TOKEN helper — a github.com push would not authenticate as the SOURCE account"
    printf '%s\n' "$out" | sed -E 's/^password=.+/password=<redacted>/'
    exit 1
  fi
