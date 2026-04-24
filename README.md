# gitlab-inline-comments

Post review comments to GitLab Merge Requests as **inline, diff-positioned discussion threads** — with graceful fallback when exact positioning isn't possible.

Two small, focused Bash scripts. Hit the GitLab REST API directly. No framework, no runtime, no node_modules.

```bash
./post-inline-comment.sh \
  --project my-group/my-project --mr 1234 \
  --new-path src/api/handler.ts --line-type added --new-line 42 \
  --base-sha "$BASE" --head-sha "$HEAD" --start-sha "$START" \
  --body-file /tmp/comment.md
# -> COMMENT_POST: status=posted tier=1 http=201 project=my-group/my-project mr=1234 file=src/api/handler.ts line=42
```

---

## Why this exists

GitLab's own MCP (Model Context Protocol) connector exposes read operations for MRs (`get_merge_request`, `get_merge_request_diffs`, etc.) but its write tool — `create_workitem_note` — can only create **general** MR notes. It doesn't support diff-positioned inline comments.

If you're building a code-review agent that reads an MR diff, forms opinions about specific lines, and wants to post those opinions **next to the lines they refer to**, the MCP surface alone leaves you stranded on general-note fallback — comments drift away from the code they're about, and reviewers can't resolve them per-thread.

This project fills that gap using the GitLab REST API (`POST /projects/:id/merge_requests/:iid/discussions` with a `position[...]` payload). It's designed to be called from a code-review agent, a CI pipeline, or any script that wants inline comments without pulling in a full GitLab SDK.

## The 3-tier fallback

The hard part of positioned GitLab comments isn't the happy path — it's that **GitLab rejects the post with 400 whenever the target line isn't considered "visible" in the MR diff view**. Diff truncation, context collapsing, and whitespace-only changes can all make an otherwise-real line un-targetable. A naive integration drops the comment on the floor.

This tool handles that with three tiers:

| Tier | What it is | When it fires |
|------|------------|---------------|
| **1. Exact inline** | `position[new_line]=42` at the caller's target line. | The line is directly addressable in the diff. |
| **2. Nearest-hunk anchor** *(caller-assisted)* | Posts at caller-provided `--anchor-new-line` / `--anchor-old-line` as a `context`-type position, with a `📍` note explaining the re-anchor. | Tier 1 returned non-201 **or** GitLab silently downgraded the note (see below). The caller pre-computes the nearest visible line from its own diff data. |
| **3. General discussion** | Plain MR-level note with `📍 \`path\` line N` prepended. | Tier 1 and Tier 2 both failed, or `--line-type=none` was passed for architectural comments. |

### The silent-downgrade check

GitLab will sometimes respond `201 Created` to a positioned post while silently discarding the position, producing an unpositioned `Note` rather than a `DiffNote`. Treating that as success means you think you posted inline — but the comment is floating in general discussion.

`post-inline-comment.sh` checks `notes[0].type == "DiffNote"` on the response body and only claims Tier-1 success if that check passes. Otherwise it falls through to Tier 2. This was not obvious from the API docs — it surfaced from watching real MR output diverge from the status code.

### Why caller-assisted Tier 2?

Computing the "nearest visible diff line" correctly requires parsing the MR's diff hunks, which the caller typically already has in memory (that's how it knew the target line in the first place). Rather than re-fetching diffs inside this tool and picking a line with incomplete context, the tool accepts the anchor as input. This keeps the tool stateless and the nearest-hunk logic in the one place that has the full picture.

## Install

Clone anywhere and mark the scripts executable:

```bash
git clone https://github.com/chrisarmitt/gitlab-inline-comments.git
cd gitlab-inline-comments
chmod +x *.sh
```

Requirements: `bash`, `curl`, `python3` (with `pyyaml`; only needed if you auth via `glab` config rather than `GITLAB_TOKEN`).

## Auth

Two options, checked in order:

1. **`GITLAB_TOKEN` env var** — a [personal access token](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html) with `api` scope. Preferred for CI.
2. **`glab` CLI config** at `~/.config/glab-cli/config.yml`. If you already use `glab auth login`, the scripts reuse that token.

The authenticated user needs at least **Developer** role on the target project to create discussion threads.

## Self-hosted GitLab

Set `GITLAB_HOST` to point at your instance:

```bash
export GITLAB_HOST=https://gitlab.example.com
export GITLAB_TOKEN=glpat-...
./post-inline-comment.sh --project ...
```

Defaults to `https://gitlab.com`.

## Usage

### Step 1 — Fetch diff refs (once per MR)

Inline comments must be anchored to a specific MR version identified by three SHAs — `base_sha`, `head_sha`, `start_sha`. GitLab exposes these on the MR object.

```bash
REFS=$(./get-diff-refs.sh my-group/my-project 1234)
BASE_SHA=$(echo "$REFS"  | grep -oP 'base_sha=\K\S+')
HEAD_SHA=$(echo "$REFS"  | grep -oP 'head_sha=\K\S+')
START_SHA=$(echo "$REFS" | grep -oP 'start_sha=\K\S+')
```

### Step 2 — Write the comment body to a file

```bash
cat > /tmp/comment.md <<'EOF'
**Missing null check on query result**

`.find()` on line 42 can return `undefined`, but the result is used directly on line 43 without a guard.

**Suggestion:** add a null check, or use a fallback value.
EOF
```

### Step 3 — Post

```bash
./post-inline-comment.sh \
  --project my-group/my-project \
  --mr 1234 \
  --new-path src/services/orderService.ts \
  --line-type added \
  --new-line 42 \
  --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA" --start-sha "$START_SHA" \
  --body-file /tmp/comment.md
```

### Step 4 — Parse the result

Every run prints a single machine-parseable line:

```
COMMENT_POST: status={posted|fallback|failed} tier={1|2|3} http={code} project={path} mr={iid} file={path} line={N}
```

Map `status` → action:

| `status` | Meaning | What a caller should do |
|----------|---------|-------------------------|
| `posted` | Inline success (Tier 1 or Tier 2) | Continue |
| `fallback` | Inline failed, general discussion posted (Tier 3) | Continue — comment is visible, just not inline |
| `failed` | All tiers failed | Collect body for manual posting; don't assume comment is visible |

## Parameters — `post-inline-comment.sh`

| Flag | Required | Description |
|------|----------|-------------|
| `--project` | Yes | Full project path (script URL-encodes it) |
| `--mr` | Yes | MR internal ID |
| `--body-file` | Yes | Path to a file containing the comment body (Markdown) |
| `--base-sha` / `--head-sha` / `--start-sha` | Yes | From `get-diff-refs.sh` |
| `--new-path` | Yes | File path in the new version |
| `--old-path` | No | File path in the old version. Defaults to `--new-path`. Set for renames. |
| `--line-type` | Yes | `added`, `removed`, `changed`, `context`, or `none` |
| `--new-line` | Conditional | Required for `added`, `changed`, `context` |
| `--old-line` | Conditional | Required for `removed`, `context` |
| `--anchor-new-line` / `--anchor-old-line` | No | Tier 2 anchor — nearest visible line in the diff |

### Line-type cheat sheet

| Line in diff | `--line-type` | `--old-line` | `--new-line` |
|--------------|---------------|--------------|--------------|
| `+` added | `added` | — | ✓ |
| `-` removed | `removed` | ✓ | — |
| `-`/`+` pair (replacement) | `changed` | — | ✓ (the new line) |
| Unprefixed (context) | `context` | ✓ | ✓ |
| Not in diff (architectural comment) | `none` | — | — |

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Posted (any tier) |
| `1`  | Auth failure — comment not posted |
| `2`  | All tiers failed / bad input |

## Rate limiting

GitLab will throttle if you hammer a single MR. If posting more than ~10 comments to one MR, sleep 1s between calls:

```bash
for finding in "${findings[@]}"; do
  ./post-inline-comment.sh ...
  sleep 1
done
```

## Using as a Claude Code skill

The scripts were originally built as a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill for agentic code-review pipelines. A `SKILL.md` is included at the repo root. To install as a skill:

```bash
mkdir -p ~/.claude/skills/gitlab-inline-comments
cp -r ./* ~/.claude/skills/gitlab-inline-comments/
chmod +x ~/.claude/skills/gitlab-inline-comments/*.sh
```

An agent can then invoke the skill to post findings inline as part of a review pass.

## Credits

Originally written by Chris Armitt. Refined collaboratively Claude (Anthropic) during production use in an agentic code-review pipeline.

## License

MIT — see [LICENSE](./LICENSE).
