# pr-media

An [Agent Skill](https://agentskills.io/) that attaches screenshots and screen recordings to a GitHub PR description.

The agent delegates capture to a cheap subagent (Haiku 5.5 or newer), spot-checks one frame, and runs `scripts/pr-media.sh`. The script uploads the files and keeps one `<!-- pr-media -->` block in the PR body up to date.

## Install

The skill folder name must be `pr-media`.

```bash
# for every project
git clone git@github.com:H1D/pr-media-skill.git ~/.claude/skills/pr-media
# or for one project
git clone git@github.com:H1D/pr-media-skill.git .claude/skills/pr-media
```

Requirements: `gh` (authenticated), `git`, `node`, and `ffmpeg` for videos. `gh` 2.99.0 or newer enables the default backend.

## Script

```bash
scripts/pr-media.sh [--no-edit] <pr-number> <file>...
```

Images: png, jpg, jpeg, webp, gif. Videos: mp4, webm, mov, mkv (re-encoded to H.264 MP4, ≤1280 px wide). File names become captions.

### Backends

| | `attach` (default) | `branch` (fallback) |
|---|---|---|
| How | `gh pr edit --attach` → user-attachments CDN | commit to orphan branch `pr-assets/pr-<N>`, link by SHA |
| Needs | gh ≥ 2.99.0 | push access |
| Visibility | same as drag-and-drop: private repo stays private | anyone who can read the repo |
| Video | inline player | GIF preview linking to the MP4 |
| Size limit | 10 MB per file (videos 100 MB on paid plans) | 25 MB per file |

`auto` uses `attach` when gh supports it and every file fits, else `branch`. `--no-edit` (print the block, don't edit the PR) uses `branch`.

### Environment

| Variable | Default | |
|---|---|---|
| `PR_MEDIA_BACKEND` | `auto` | `auto`, `attach`, `branch` |
| `PR_MEDIA_ATTACH_MAX_MB` | `10` | raise to `100` for videos on paid plans |
| `PR_MEDIA_IMG_WIDTH` | `720` | display width in the PR |
| `PR_MEDIA_GIF_WIDTH` / `PR_MEDIA_GIF_FPS` | `720` / `10` | GIF previews (branch backend) |
| `PR_MEDIA_GH` | `gh` | gh binary to use |

### Re-runs

Each file is one item in the block, keyed by its name. Re-running replaces items with the same name and keeps the rest, so you can add an "after" shot later without re-uploading the "before".
