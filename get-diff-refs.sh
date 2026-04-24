#!/usr/bin/env bash
#
# get-diff-refs.sh — Retrieve diff_refs SHAs for a GitLab MR
#
# Usage: ./get-diff-refs.sh <PROJECT_PATH> <MR_IID>
#
# PROJECT_PATH is the raw GitLab path (e.g. my-group/my-project).
# The script handles URL encoding internally.
#
# Auth (in order of precedence):
#   1. $GITLAB_TOKEN  — personal access token (scope: api)
#   2. glab-cli config at ~/.config/glab-cli/config.yml
#
# Host:
#   Defaults to https://gitlab.com. Override with $GITLAB_HOST for self-hosted
#   (e.g. GITLAB_HOST=https://gitlab.example.com).
#
# Output: DIFF_REFS: status=ok base_sha=<sha> head_sha=<sha> start_sha=<sha>
#
# Exit codes:
#   0 = success
#   1 = auth failure or MR not found
#   2 = other failure (no config, network error, parse error)
#

set -euo pipefail

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,/^[^#]/{/^#/{ s/^# \?//; p; }}' "${BASH_SOURCE[0]}"
  exit 0
fi

# --- Validate inputs ---

if [[ $# -lt 2 ]]; then
  echo "DIFF_REFS: status=error msg=usage: $0 PROJECT_PATH MR_IID"
  exit 2
fi

PROJECT_PATH="$1"
MR_IID="$2"

# --- Resolve host ---

GITLAB_HOST_URL="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_HOST_URL="${GITLAB_HOST_URL%/}"
GITLAB_HOST_BARE="${GITLAB_HOST_URL#https://}"
GITLAB_HOST_BARE="${GITLAB_HOST_BARE#http://}"

# --- URL-encode project path (replace / with %2F) ---

ENCODED_PATH="${PROJECT_PATH//\//%2F}"

# --- Resolve GitLab token: env var wins, then glab-cli config ---

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  GLAB_CONFIG="$HOME/.config/glab-cli/config.yml"

  if [[ ! -f "$GLAB_CONFIG" ]]; then
    echo "DIFF_REFS: status=error msg=no GITLAB_TOKEN and no glab config at ${GLAB_CONFIG} — set GITLAB_TOKEN or run 'glab auth login'"
    exit 2
  fi

  GITLAB_TOKEN=$(python3 -c "
import yaml, re, sys
host = '${GITLAB_HOST_BARE}'
raw = open('${GLAB_CONFIG}').read()
# glab writes 'token: !!null <actual-token>' — strip the !!null tag so PyYAML parses it as a string
cleaned = re.sub(r'token:\s+!!null\s+', 'token: ', raw)
cfg = yaml.safe_load(cleaned) or {}
hosts = cfg.get('hosts', {}) or {}
entry = hosts.get(host) or {}
token = entry.get('token') or ''
print(token)
" 2>/dev/null || echo "")

  if [[ -z "$GITLAB_TOKEN" ]]; then
    echo "DIFF_REFS: status=error msg=could not extract token for host=${GITLAB_HOST_BARE} from glab config"
    exit 2
  fi
fi

# --- Fetch MR metadata ---

RESPONSE=$(curl -s -w "\n%{http_code}" \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_HOST_URL}/api/v4/projects/${ENCODED_PATH}/merge_requests/${MR_IID}")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

case "$HTTP_CODE" in
  200) ;;
  401|403)
    echo "DIFF_REFS: status=auth_failed http=${HTTP_CODE} project=${PROJECT_PATH} mr=${MR_IID}"
    exit 1
    ;;
  404)
    echo "DIFF_REFS: status=not_found http=404 project=${PROJECT_PATH} mr=${MR_IID}"
    exit 1
    ;;
  *)
    echo "DIFF_REFS: status=error http=${HTTP_CODE} project=${PROJECT_PATH} mr=${MR_IID}"
    exit 2
    ;;
esac

# --- Extract diff_refs ---

DIFF_REFS=$(echo "$BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
dr = data.get('diff_refs')
if not dr:
    print('ERROR: no diff_refs in response')
    sys.exit(1)
print(f\"{dr['base_sha']} {dr['head_sha']} {dr['start_sha']}\")
" 2>/dev/null) || {
  echo "DIFF_REFS: status=error msg=could not extract diff_refs from MR response project=${PROJECT_PATH} mr=${MR_IID}"
  exit 2
}

if [[ -z "$DIFF_REFS" ]] || [[ "$DIFF_REFS" == ERROR:* ]]; then
  echo "DIFF_REFS: status=error msg=could not extract diff_refs from MR response project=${PROJECT_PATH} mr=${MR_IID}"
  exit 2
fi

BASE_SHA=$(echo "$DIFF_REFS" | awk '{print $1}')
HEAD_SHA=$(echo "$DIFF_REFS" | awk '{print $2}')
START_SHA=$(echo "$DIFF_REFS" | awk '{print $3}')

echo "DIFF_REFS: status=ok base_sha=${BASE_SHA} head_sha=${HEAD_SHA} start_sha=${START_SHA}"
exit 0
