#!/bin/bash
# Hosted CI only: keep dependency credentials in a restricted, temporary Git config.
set +x
set -euo pipefail
if [[ -z "${PLAYER_SDK_READ_TOKEN:-}" ]]; then
  echo '::error::Set the PLAYER_SDK_READ_TOKEN repository secret to a token with read-only contents access to the private player SDK repository. GITHUB_TOKEN cannot clone that dependency.' >&2
  exit 1
fi
if [[ ! "$PLAYER_SDK_READ_TOKEN" =~ ^[[:alnum:]_-]+$ ]]; then
  echo '::error::PLAYER_SDK_READ_TOKEN has an invalid format.' >&2
  exit 1
fi
: "${RUNNER_TEMP:?Hosted runner temporary directory is required}"
: "${GITHUB_ENV:?Hosted runner environment file is required}"
umask 077
config=$(mktemp "$RUNNER_TEMP/player-dependency-git.XXXXXX")
trap 'rm -f "$config"' ERR
git config --file "$config" "url.https://x-access-token:${PLAYER_SDK_READ_TOKEN}@github.com/hotmic-wp/.insteadOf" 'https://github.com/hotmic-wp/'
printf 'GIT_CONFIG_GLOBAL=%s\n' "$config" >> "$GITHUB_ENV"
