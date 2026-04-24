---
name: gitlab-inline-comments
description: Posts review comments to GitLab MRs as inline diff-positioned discussion threads. Handles the 3-tier fallback (exact line → nearest hunk → general discussion) required by GitLab's diff positioning API, which the GitLab MCP connector does not support for write operations.
---

# GitLab Inline Comments

Posts review comments to GitLab Merge Requests as positioned inline discussion threads, anchored to specific lines in the diff. Falls back gracefully when exact positioning isn't possible.

The GitLab MCP connector supports reading MR data (`get_merge_request`, `get_merge_request_diffs`, etc.) but its write tool (`create_workitem_note`) does not support diff-positioned inline comments — it can only create general MR notes. This skill fills that gap using the GitLab REST API (`POST /projects/:id/merge_requests/:iid/discussions`).

## Prerequisites

Authenticate via **either** of:

1. **`GITLAB_TOKEN` env var** (preferred for CI) — a personal access token with `api` scope.
2. **`glab` CLI** authenticated via `glab auth login` — scripts read the token from `~/.config/glab-cli/config.yml`.

For self-hosted GitLab, set `GITLAB_HOST=https://gitlab.example.com` (defaults to `https://gitlab.com`).

**Required GitLab permissions:** the authenticated user must have at least Developer role on the target project.

## Scripts

### get-diff-refs.sh

Retrieves the `diff_refs` SHAs required for positioning inline comments. These are specific to each MR version and must be fetched before posting.

```bash
~/.claude/skills/gitlab-inline-comments/get-diff-refs.sh <PROJECT_PATH> <MR_IID>
```

**Arguments:**
| Arg | Description | Example |
|-----|-------------|---------|
| `PROJECT_PATH` | Full GitLab project path (raw — script handles URL encoding) | `my-group/my-project` |
| `MR_IID` | MR internal ID (the number shown in the UI) | `1234` |

**Output** (single parseable line on success):

```
DIFF_REFS: status=ok base_sha=abc123 head_sha=def456 start_sha=ghi789
```

**Exit codes:**
| Code | Meaning |
|------|---------|
| `0` | Success — SHAs returned |
| `1` | Auth failure or MR not found |
| `2` | Other failure (no config, network error) |

### post-inline-comment.sh

Posts a single comment to an MR with automatic fallback:

1. **Tier 1 — Exact inline**: Anchored to the precise diff line. Requires the target line to be addressable in the diff view.
2. **Tier 2 — Nearest hunk** (caller-assisted): If the caller provides `--anchor-new-line` and `--anchor-old-line`, posts as a `context` line at that position with a `📍` location note prepended. The caller is responsible for computing the nearest hunk anchor — the script just posts at the given coordinates.
3. **Tier 3 — General discussion**: Plain MR discussion thread with a `📍` file/line reference in the body. Used when inline positioning fails or `--line-type` is `none`.

```bash
~/.claude/skills/gitlab-inline-comments/post-inline-comment.sh \
  --project "my-group/my-project" \
  --mr 1234 \
  --new-path "src/services/orderService.ts" \
  --old-path "src/services/orderService.ts" \
  --line-type added \
  --new-line 42 \
  --base-sha abc123 \
  --head-sha def456 \
  --start-sha ghi789 \
  --body-file /tmp/comment_body.txt
```

**Parameters:**

| Flag | Required | Description |
|------|----------|-------------|
| `--project` | Yes | Full GitLab project path (raw — script handles URL encoding) |
| `--mr` | Yes | MR internal ID |
| `--body-file` | Yes | Path to a file containing the comment body (Markdown) |
| `--base-sha` | Yes | From `get-diff-refs.sh` output |
| `--head-sha` | Yes | From `get-diff-refs.sh` output |
| `--start-sha` | Yes | From `get-diff-refs.sh` output |
| `--new-path` | Yes | File path in the new version (post-MR) |
| `--old-path` | No | File path in the old version. Defaults to `--new-path`. Set explicitly for renamed/moved files. |
| `--line-type` | Yes | One of: `added`, `removed`, `changed`, `context`, `none` |
| `--new-line` | Conditional | Required for `added`, `changed`, `context` |
| `--old-line` | Conditional | Required for `removed`, `context` |
| `--anchor-new-line` | No | Tier 2 override: anchor to this new_line instead (nearest hunk) |
| `--anchor-old-line` | No | Tier 2 override: anchor to this old_line instead (nearest hunk) |

**Output** (single parseable line):

```
COMMENT_POST: status={posted|fallback|failed} tier={1|2|3} http={code} project={path} mr={iid} file={new_path} line={number}
```

| Status | Meaning |
|--------|---------|
| `posted` | Comment successfully posted inline (Tier 1 or Tier 2) |
| `fallback` | Inline posting failed — posted as general discussion (Tier 3) |
| `failed` | All tiers failed — comment not posted |

**Exit codes:**
| Code | Meaning | Caller action |
|------|---------|---------------|
| `0` | Posted successfully (any tier) | Continue |
| `1` | Auth failure | Stop — check `GITLAB_TOKEN` or glab auth |
| `2` | All tiers failed | Log the failure, collect body for manual posting |

## Recommended Workflow

_Examples below use `my-group/my-project` and `1234` as placeholders — substitute the real project path and MR IID at call time._

This is the pattern a calling agent (e.g. a review command) should follow:

### 1. Get diff refs (once per MR)

```bash
REFS=$(~/.claude/skills/gitlab-inline-comments/get-diff-refs.sh "my-group/my-project" 1234)

BASE_SHA=$(echo "$REFS" | grep -oP 'base_sha=\K\S+')
HEAD_SHA=$(echo "$REFS" | grep -oP 'head_sha=\K\S+')
START_SHA=$(echo "$REFS" | grep -oP 'start_sha=\K\S+')
```

### 2. Write comment body to a temp file

```bash
cat > /tmp/review_1234_comment_1.txt << '__EOF__'
[BLOCKING] **Missing null check on query result**

The `.find()` on line 42 can return `undefined` but the result is used directly on line 43 without a guard.

**Suggestion**: Add a null check before accessing `.id`, or use a fallback value.
__EOF__
```

### 3. Post the comment

```bash
~/.claude/skills/gitlab-inline-comments/post-inline-comment.sh \
  --project "my-group/my-project" \
  --mr 1234 \
  --new-path "src/services/orderService.ts" \
  --old-path "src/services/orderService.ts" \
  --line-type added \
  --new-line 42 \
  --base-sha "$BASE_SHA" \
  --head-sha "$HEAD_SHA" \
  --start-sha "$START_SHA" \
  --body-file /tmp/review_1234_comment_1.txt
```

### 4. Check the result

Parse the output line. If `status=failed`, collect the comment body for manual posting at the end of the pipeline.

### Tier 2 — Nearest hunk (caller-assisted)

If you have diff hunk data and want to anchor to the nearest visible line when exact positioning fails, pre-compute the anchor coordinates and pass them:

```bash
~/.claude/skills/gitlab-inline-comments/post-inline-comment.sh \
  --project "my-group/my-project" \
  --mr 1234 \
  --new-path "src/services/orderService.ts" \
  --old-path "src/services/orderService.ts" \
  --line-type context \
  --new-line 87 \
  --old-line 85 \
  --anchor-new-line 80 \
  --anchor-old-line 78 \
  --base-sha "$BASE_SHA" \
  --head-sha "$HEAD_SHA" \
  --start-sha "$START_SHA" \
  --body-file /tmp/review_1234_comment_1.txt
```

The script will attempt Tier 1 first (exact line), then Tier 2 with the anchor coordinates (prepending a `📍` note), then Tier 3 as final fallback.

### Rate limiting

If posting more than 10 comments to a single MR, insert a 1-second delay between calls:

```bash
if [[ $comment_count -gt 10 ]]; then
  sleep 1
fi
```

### Line type reference

When recording findings, classify each target line against the MR diff:

| Line in diff | `--line-type` | Include `--old-line` | Include `--new-line` |
|--------------|---------------|----------------------|----------------------|
| `+` prefixed (added) | `added` | No | Yes |
| `-` prefixed (removed) | `removed` | Yes | No |
| `-`/`+` pair (replacement) | `changed` | No | Yes (the new line) |
| No prefix (context) | `context` | Yes | Yes |
| Not in diff / architectural | `none` | No | No |

For `none`, the script skips straight to Tier 3 (general discussion).
