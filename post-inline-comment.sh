#!/usr/bin/env bash
#
# post-inline-comment.sh — Post a comment to a GitLab MR with 3-tier fallback
#
# Tier 1: Exact inline (diff-positioned discussion thread)
# Tier 2: Nearest hunk (caller provides anchor coordinates)
# Tier 3: General discussion (fallback with file/line reference in body)
#
# Auth (in order of precedence):
#   1. $GITLAB_TOKEN  — personal access token (scope: api)
#   2. glab-cli config at ~/.config/glab-cli/config.yml
#
# Host:
#   Defaults to https://gitlab.com. Override with $GITLAB_HOST for self-hosted
#   (e.g. GITLAB_HOST=https://gitlab.example.com).
#
# Usage:
#   ./post-inline-comment.sh \
#     --project <group/project> \
#     --mr <iid> \
#     --new-path <file> \
#     --line-type <added|removed|changed|context|none> \
#     [--new-line N] [--old-line N] [--old-path file] \
#     [--anchor-new-line N --anchor-old-line N] \
#     --base-sha <sha> --head-sha <sha> --start-sha <sha> \
#     --body-file <path>
#
# Output: COMMENT_POST: status={posted|fallback|failed} tier={1|2|3} http={code} project={path} mr={iid} file={path} line={number}
#
# Exit codes:
#   0 = posted (any tier)
#   1 = auth failure
#   2 = all tiers failed / bad input
#

set -euo pipefail

# --- Inline help ---

show_help() {
  sed -n '2,/^[^#]/{/^#/{ s/^# \?//; p; }}' "${BASH_SOURCE[0]}"
  exit 0
}

# --- Defaults ---

PROJECT=""
MR_IID=""
NEW_PATH=""
OLD_PATH=""
LINE_TYPE=""
NEW_LINE=""
OLD_LINE=""
ANCHOR_NEW_LINE=""
ANCHOR_OLD_LINE=""
BASE_SHA=""
HEAD_SHA=""
START_SHA=""
BODY_FILE=""

# --- Parse named arguments ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)         PROJECT="$2";         shift 2 ;;
    --mr)              MR_IID="$2";          shift 2 ;;
    --new-path)        NEW_PATH="$2";        shift 2 ;;
    --old-path)        OLD_PATH="$2";        shift 2 ;;
    --line-type)       LINE_TYPE="$2";       shift 2 ;;
    --new-line)        NEW_LINE="$2";        shift 2 ;;
    --old-line)        OLD_LINE="$2";        shift 2 ;;
    --anchor-new-line) ANCHOR_NEW_LINE="$2"; shift 2 ;;
    --anchor-old-line) ANCHOR_OLD_LINE="$2"; shift 2 ;;
    --base-sha)        BASE_SHA="$2";        shift 2 ;;
    --head-sha)        HEAD_SHA="$2";        shift 2 ;;
    --start-sha)       START_SHA="$2";       shift 2 ;;
    --body-file)       BODY_FILE="$2";       shift 2 ;;
    --help|-h)         show_help ;;
    *)
      echo "COMMENT_POST: status=failed tier=0 http=0 project=unknown mr=unknown file=unknown line=0 msg=unknown argument: $1"
      exit 2
      ;;
  esac
done

# --- Validate required inputs ---

MISSING=""
[[ -z "$PROJECT" ]]   && MISSING="${MISSING} --project"
[[ -z "$MR_IID" ]]    && MISSING="${MISSING} --mr"
[[ -z "$NEW_PATH" ]]  && MISSING="${MISSING} --new-path"
[[ -z "$LINE_TYPE" ]] && MISSING="${MISSING} --line-type"
[[ -z "$BASE_SHA" ]]  && MISSING="${MISSING} --base-sha"
[[ -z "$HEAD_SHA" ]]  && MISSING="${MISSING} --head-sha"
[[ -z "$START_SHA" ]] && MISSING="${MISSING} --start-sha"
[[ -z "$BODY_FILE" ]] && MISSING="${MISSING} --body-file"

if [[ -n "$MISSING" ]]; then
  echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT:-unknown} mr=${MR_IID:-unknown} file=${NEW_PATH:-unknown} line=0 msg=missing required args:${MISSING}"
  exit 2
fi

if [[ ! -f "$BODY_FILE" ]]; then
  echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0 msg=body file not found: ${BODY_FILE}"
  exit 2
fi

# Default old_path to new_path if not set (non-rename case)
[[ -z "$OLD_PATH" ]] && OLD_PATH="$NEW_PATH"

# Validate line_type
case "$LINE_TYPE" in
  added|removed|changed|context|none) ;;
  *)
    echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0 msg=invalid --line-type: ${LINE_TYPE}"
    exit 2
    ;;
esac

# Validate conditional line number requirements
if [[ "$LINE_TYPE" == "added" || "$LINE_TYPE" == "changed" ]] && [[ -z "$NEW_LINE" ]]; then
  echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0 msg=--new-line required for line-type=${LINE_TYPE}"
  exit 2
fi

if [[ "$LINE_TYPE" == "removed" ]] && [[ -z "$OLD_LINE" ]]; then
  echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0 msg=--old-line required for line-type=${LINE_TYPE}"
  exit 2
fi

if [[ "$LINE_TYPE" == "context" ]] && { [[ -z "$NEW_LINE" ]] || [[ -z "$OLD_LINE" ]]; }; then
  echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0 msg=--new-line and --old-line both required for line-type=context"
  exit 2
fi

# Determine the display line number (for output and fallback body)
DISPLAY_LINE="${NEW_LINE:-${OLD_LINE:-0}}"

# --- Resolve host ---

GITLAB_HOST_URL="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_HOST_URL="${GITLAB_HOST_URL%/}"
GITLAB_HOST_BARE="${GITLAB_HOST_URL#https://}"
GITLAB_HOST_BARE="${GITLAB_HOST_BARE#http://}"

# --- URL-encode project path ---

ENCODED_PATH="${PROJECT//\//%2F}"

# --- Resolve GitLab token: env var wins, then glab-cli config ---

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  GLAB_CONFIG="$HOME/.config/glab-cli/config.yml"

  if [[ ! -f "$GLAB_CONFIG" ]]; then
    echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE} msg=no GITLAB_TOKEN and no glab config — set GITLAB_TOKEN or run 'glab auth login'"
    exit 1
  fi

  GITLAB_TOKEN=$(python3 -c "
import yaml, re, sys
host = '${GITLAB_HOST_BARE}'
raw = open('${GLAB_CONFIG}').read()
cleaned = re.sub(r'token:\s+!!null\s+', 'token: ', raw)
cfg = yaml.safe_load(cleaned) or {}
hosts = cfg.get('hosts', {}) or {}
entry = hosts.get(host) or {}
token = entry.get('token') or ''
print(token)
" 2>/dev/null || echo "")

  if [[ -z "$GITLAB_TOKEN" ]]; then
    echo "COMMENT_POST: status=failed tier=0 http=0 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE} msg=could not extract token for host=${GITLAB_HOST_BARE}"
    exit 1
  fi
fi

# --- API base URL ---

API_URL="${GITLAB_HOST_URL}/api/v4/projects/${ENCODED_PATH}/merge_requests/${MR_IID}/discussions"

# --- Helper: build curl position args based on line_type ---

build_position_args() {
  local lt="$1"
  local nl="$2"
  local ol="$3"

  local args=(
    --form 'position[position_type]=text'
    --form "position[base_sha]=${BASE_SHA}"
    --form "position[start_sha]=${START_SHA}"
    --form "position[head_sha]=${HEAD_SHA}"
    --form "position[old_path]=${OLD_PATH}"
    --form "position[new_path]=${NEW_PATH}"
  )

  case "$lt" in
    added|changed)
      args+=(--form "position[new_line]=${nl}")
      ;;
    removed)
      args+=(--form "position[old_line]=${ol}")
      ;;
    context)
      args+=(--form "position[old_line]=${ol}")
      args+=(--form "position[new_line]=${nl}")
      ;;
  esac

  echo "${args[@]}"
}

# --- Skip straight to Tier 3 for line_type=none ---

if [[ "$LINE_TYPE" == "none" ]]; then
  # Tier 3: General discussion (no file/line reference since none provided)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --form "body=<${BODY_FILE}" \
    "$API_URL")

  case "$HTTP_CODE" in
    201)
      echo "COMMENT_POST: status=fallback tier=3 http=201 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0"
      exit 0
      ;;
    401|403)
      echo "COMMENT_POST: status=failed tier=3 http=${HTTP_CODE} project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0 msg=auth failure"
      exit 1
      ;;
    *)
      echo "COMMENT_POST: status=failed tier=3 http=${HTTP_CODE} project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=0"
      exit 2
      ;;
  esac
fi

# --- Tier 1: Exact inline posting ---

TIER1_ARGS=$(build_position_args "$LINE_TYPE" "$NEW_LINE" "$OLD_LINE")

TIER1_RESPONSE_FILE=$(mktemp /tmp/gitlab_comment_t1_XXXXXX.json)
# shellcheck disable=SC2086
TIER1_HTTP=$(curl -s -o "$TIER1_RESPONSE_FILE" -w "%{http_code}" \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --form "body=<${BODY_FILE}" \
  $TIER1_ARGS \
  "$API_URL")

if [[ "$TIER1_HTTP" == "201" ]]; then
  # Verify it's actually a DiffNote (not silently downgraded to a regular note)
  NOTE_TYPE=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('notes',[{}])[0].get('type',''))" < "$TIER1_RESPONSE_FILE" 2>/dev/null || echo "")
  rm -f "$TIER1_RESPONSE_FILE"

  if [[ "$NOTE_TYPE" == "DiffNote" ]]; then
    echo "COMMENT_POST: status=posted tier=1 http=201 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE}"
    exit 0
  fi
  # If not a DiffNote, fall through to Tier 2
fi

# Check for auth failure — no point trying further tiers
if [[ "$TIER1_HTTP" == "401" || "$TIER1_HTTP" == "403" ]]; then
  rm -f "$TIER1_RESPONSE_FILE"
  echo "COMMENT_POST: status=failed tier=1 http=${TIER1_HTTP} project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE} msg=auth failure"
  exit 1
fi

rm -f "$TIER1_RESPONSE_FILE"

# --- Tier 2: Nearest hunk (only if caller provided anchor coordinates) ---

if [[ -n "$ANCHOR_NEW_LINE" && -n "$ANCHOR_OLD_LINE" ]]; then
  # Build a modified body with location note prepended
  TIER2_BODY_FILE=$(mktemp /tmp/gitlab_comment_t2_body_XXXXXX.txt)
  {
    echo "📍 _This relates to line ${DISPLAY_LINE} — anchored here as the nearest diff location._"
    echo ""
    cat "$BODY_FILE"
  } > "$TIER2_BODY_FILE"

  TIER2_ARGS=$(build_position_args "context" "$ANCHOR_NEW_LINE" "$ANCHOR_OLD_LINE")

  TIER2_RESPONSE_FILE=$(mktemp /tmp/gitlab_comment_t2_XXXXXX.json)
  # shellcheck disable=SC2086
  TIER2_HTTP=$(curl -s -o "$TIER2_RESPONSE_FILE" -w "%{http_code}" \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --form "body=<${TIER2_BODY_FILE}" \
    $TIER2_ARGS \
    "$API_URL")

  rm -f "$TIER2_BODY_FILE"

  if [[ "$TIER2_HTTP" == "201" ]]; then
    rm -f "$TIER2_RESPONSE_FILE"
    echo "COMMENT_POST: status=posted tier=2 http=201 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE}"
    exit 0
  fi

  rm -f "$TIER2_RESPONSE_FILE"
fi

# --- Tier 3: General discussion fallback ---

# Build fallback body with file/line reference
TIER3_BODY_FILE=$(mktemp /tmp/gitlab_comment_t3_body_XXXXXX.txt)

ORIGINAL_BODY=$(cat "$BODY_FILE")
FIRST_LINE=$(echo "$ORIGINAL_BODY" | head -1)
REST_OF_BODY=$(echo "$ORIGINAL_BODY" | tail -n +2)

{
  echo "$FIRST_LINE"
  echo ""
  if [[ "$LINE_TYPE" == "removed" ]]; then
    echo "📍 \`${NEW_PATH}\` (removed line)"
  else
    echo "📍 \`${NEW_PATH}\` line ${DISPLAY_LINE}"
  fi
  echo "$REST_OF_BODY"
} > "$TIER3_BODY_FILE"

TIER3_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --form "body=<${TIER3_BODY_FILE}" \
  "$API_URL")

rm -f "$TIER3_BODY_FILE"

case "$TIER3_HTTP" in
  201)
    echo "COMMENT_POST: status=fallback tier=3 http=201 project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE}"
    exit 0
    ;;
  401|403)
    echo "COMMENT_POST: status=failed tier=3 http=${TIER3_HTTP} project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE} msg=auth failure"
    exit 1
    ;;
  *)
    echo "COMMENT_POST: status=failed tier=3 http=${TIER3_HTTP} project=${PROJECT} mr=${MR_IID} file=${NEW_PATH} line=${DISPLAY_LINE}"
    exit 2
    ;;
esac
