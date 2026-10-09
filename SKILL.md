---
name: pr-media
description: Attach screenshots and screen recordings to a GitHub PR description. Invoke automatically when a PR is about to be opened (or updated) and the diff changes anything users see (UI, styles, rendering, copy). Also when asked to attach screenshots or video to a PR. Skip for backend-, test-, or docs-only diffs.
---

# pr-media

The script lives next to this file: `scripts/pr-media.sh` in this skill's directory. Run it from a checkout of the PR's repo.

1. **Estimate the capture cost.** Quick means a page reachable in a running dev server, or frames you already captured. Slow means auth or fixture setup, a real third-party API run, a multi-step flow, or several viewports. If it's slow, ask the user (AskUserQuestion) before capturing: shots now, shots later, or none. If it's quick, just do it.
2. **Delegate the capture to a Haiku subagent.** Screenshots are a mechanical browser-driving job, so run them on the cheap tier: `Agent` with `subagent_type: "general-purpose"` and `model: "haiku"`.
   - **The model must be Haiku 5.5 (`claude-haiku-5-5`) or newer.** Older Haiku models drive the browser unreliably. If you know the harness maps `haiku` to an older model, omit `model` so the subagent inherits yours instead.
   - This is deliberate, and it holds even where the user's instructions otherwise avoid Haiku or small models for subagents: this capture job is the sanctioned exception.

   Pass it: the diff summary (`git diff <base>...HEAD --stat`, where `<base>` is the PR's base branch, plus the user-facing files), the dev server URL, an output folder (the gitignored scratch folder the project names in AGENTS.md/CLAUDE.md, else `mktemp -d`), and these instructions verbatim:
   - Decide which screens the diff touches and capture one PNG per screen, before/after where a baseline exists. Name files for what they show (`settings-after.png`), because the name becomes the caption.
   - Drive the browser with whatever browser tools you have: the t3 preview tools (`preview_navigate`, `preview_click`, `device_screenshot`) when `preview_status` reports available, else the chrome-devtools MCP (`navigate_page`, `take_screenshot` with a file path). Never read screenshot pixels back into context; verify the page with the text snapshot instead.
   - Video only when motion is the change (`preview_recording_start`/`stop` or equivalent), clips ≤15 s.
   - Crop out hostnames, tokens, API keys, and user emails.
   - Return only the list of file paths and a one-line description each.
3. **Spot-check one file** by reading it. It should show the change, not a login wall, spinner, or blank page. If it doesn't, recapture that one yourself.
4. **Open the PR first**, then run `scripts/pr-media.sh <pr> <files...>`. Done when it prints `attached … to PR #<N>`. If it fails, report the error; don't paste local file paths into the PR.

Facts the script relies on:
- Default backend is `gh pr edit --attach` (gh ≥ 2.99.0): files go to GitHub's user-attachments CDN, the same as drag-and-drop. In a private repo they stay private. Videos become an inline player. Each file must be ≤10 MB (videos up to 100 MB on paid plans: `PR_MEDIA_ATTACH_MAX_MB=100`).
- With an older gh, or a file over the limit, it falls back to the orphan branch `pr-assets/pr-<N>`, linked by commit SHA. Videos become a GIF that links to an MP4 (GitHub strips `<video>` that points at repo files). Each file must be ≤25 MB; shrink a GIF with `PR_MEDIA_GIF_WIDTH=540 PR_MEDIA_GIF_FPS=8`. Force a backend with `PR_MEDIA_BACKEND=attach|branch`.
- Treat uploads as permanent either way.
- The PR body gets one block between `<!-- pr-media -->` markers. Re-runs replace items with the same file name and keep the others.
- `--no-edit` prints the block instead of editing the PR (branch backend).
