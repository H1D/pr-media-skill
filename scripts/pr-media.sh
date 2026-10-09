#!/usr/bin/env bash
# Attach screenshots and screen recordings to a PR description.
#
#   pr-media.sh [--no-edit] <pr-number> <file>...
#
# Run it from a checkout of the PR's repo. The PR description gets one block
# between <!-- pr-media --> markers, one item per file, captioned with the file
# name. Re-running replaces items with the same name and keeps the rest.
#
# Two backends (PR_MEDIA_BACKEND=auto|attach|branch, default auto):
#
#   attach  `gh pr edit --attach` (gh >= 2.99.0) uploads to GitHub's
#           user-attachments CDN, the same place drag-and-drop goes. Private repos
#           keep the files private. Videos render as an inline player. Limit
#           10 MB per file on GitHub Free (videos up to 100 MB on paid plans:
#           PR_MEDIA_ATTACH_MAX_MB=100).
#   branch  Files are committed to the orphan branch pr-assets/pr-<N> and linked
#           by commit SHA, so links survive the branch moving or being deleted.
#           Visible to whoever can read the repo. Videos become a GIF preview
#           that links to an MP4, because GitHub strips <video> tags that point
#           at repo files. Limit 25 MB per file. Uses git plumbing against a
#           throwaway index: working tree, current branch and hooks are untouched.
#
# auto picks attach when gh supports it and every file fits, else branch.
# --no-edit prints the block instead of editing the PR (branch backend only).
#
# Needs: gh, git, node; ffmpeg for videos.
# Env:   PR_MEDIA_BACKEND, PR_MEDIA_ATTACH_MAX_MB (10), PR_MEDIA_IMG_WIDTH (720,
#        display width in the PR), PR_MEDIA_GIF_WIDTH (720), PR_MEDIA_GIF_FPS (10),
#        PR_MEDIA_GH (gh binary to use, default gh).
set -euo pipefail

usage() { echo "usage: pr-media.sh [--no-edit] <pr-number> <file>..." >&2; exit 1; }

EDIT_BODY=1
if [[ "${1:-}" == "--no-edit" ]]; then EDIT_BODY=0; shift; fi
PR=${1:-}
shift || true
[[ "$PR" =~ ^[0-9]+$ && $# -gt 0 ]] || usage

GH=${PR_MEDIA_GH:-gh}
BACKEND=${PR_MEDIA_BACKEND:-auto}
ATTACH_MAX_BYTES=$((${PR_MEDIA_ATTACH_MAX_MB:-10} * 1024 * 1024))
# GitHub rejects pushes with files over 100 MB and won't render big raw images.
BRANCH_MAX_BYTES=$((25 * 1024 * 1024))
IMG_WIDTH=${PR_MEDIA_IMG_WIDTH:-720}
GIF_WIDTH=${PR_MEDIA_GIF_WIDTH:-720}
GIF_FPS=${PR_MEDIA_GIF_FPS:-10}
BRANCH="pr-assets/pr-$PR"
LOCAL_REF="refs/pr-media/pr-$PR"

case "$BACKEND" in auto | attach | branch) ;; *) echo "error: PR_MEDIA_BACKEND must be auto, attach or branch" >&2; exit 1 ;; esac
if ((EDIT_BODY == 0)); then
  [[ "$BACKEND" != attach ]] || { echo "error: --no-edit works only with the branch backend" >&2; exit 1; }
  BACKEND=branch
fi

REPO=$("$GH" repo view --json nameWithOwner -q .nameWithOwner)
"$GH" pr view "$PR" --json number >/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/out"

slug() {
  local base
  base=$(basename "$1")
  base=${base%.*}
  echo "$base" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^[-.]*//;s/-*$//'
}

# Every output name must be new: two inputs slugging to one name (before/viewer.png and
# after/viewer.png, or demo.webm next to demo.gif) would silently overwrite each other.
claim() {
  local src=$1
  shift
  for out in "$@"; do
    [[ ! -e "$TMP/out/$out" ]] || {
      echo "error: $src would be uploaded as $out, which another input already uses; rename one (e.g. before-/after- prefixes)" >&2
      exit 1
    }
  done
}

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

VIDEOS=()
for src in "$@"; do
  [[ -f "$src" ]] || { echo "error: no such file: $src" >&2; exit 1; }
  name=$(slug "$src")
  [[ -n "$name" ]] || { echo "error: cannot derive an ASCII file name from $src; rename it" >&2; exit 1; }
  ext=$(echo "${src##*.}" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    png | jpg | jpeg | webp | gif)
      claim "$src" "$name.$ext"
      cp "$src" "$TMP/out/$name.$ext"
      ;;
    mp4 | webm | mov | mkv)
      command -v ffmpeg >/dev/null || { echo "error: ffmpeg is required for videos" >&2; exit 1; }
      claim "$src" "$name.mp4" "$name.gif"
      echo "converting $src → $name.mp4"
      ffmpeg -loglevel error -y -i "$src" -an -c:v libx264 -pix_fmt yuv420p -preset slow -crf 26 \
        -vf "scale='trunc(min(1280,iw)/2)*2':-2" -movflags +faststart "$TMP/out/$name.mp4"
      VIDEOS+=("$name")
      ;;
    *)
      echo "error: unsupported file type: $src" >&2
      exit 1
      ;;
  esac
done

if [[ "$BACKEND" == auto ]]; then
  BACKEND=attach
  if ! "$GH" pr edit --help 2>/dev/null | grep -q -- '--attach'; then
    echo "gh $("$GH" --version | head -1 | awk '{print $3}') has no --attach (needs 2.99.0+); using the branch backend"
    BACKEND=branch
  else
    for f in "$TMP/out"/*; do
      if (($(file_size "$f") > ATTACH_MAX_BYTES)); then
        echo "$(basename "$f") is over $((ATTACH_MAX_BYTES / 1024 / 1024)) MB; using the branch backend"
        BACKEND=branch
        break
      fi
    done
  fi
fi

if [[ "$BACKEND" == branch ]]; then
  for name in "${VIDEOS[@]+"${VIDEOS[@]}"}"; do
    ffmpeg -loglevel error -y -i "$TMP/out/$name.mp4" -vf \
      "fps=$GIF_FPS,scale='min($GIF_WIDTH,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
      "$TMP/out/$name.gif"
  done
  MAX_BYTES=$BRANCH_MAX_BYTES
  SHRINK="Trim the clip, or lower PR_MEDIA_GIF_WIDTH / PR_MEDIA_GIF_FPS."
else
  MAX_BYTES=$ATTACH_MAX_BYTES
  SHRINK="Trim the clip, raise PR_MEDIA_ATTACH_MAX_MB on a paid plan, or use PR_MEDIA_BACKEND=branch."
fi
for f in "$TMP/out"/*; do
  size=$(file_size "$f")
  if ((size > MAX_BYTES)); then
    echo "error: $(basename "$f") is $((size / 1024 / 1024)) MB (limit $((MAX_BYTES / 1024 / 1024)) MB for the $BACKEND backend)." >&2
    echo "  $SHRINK" >&2
    exit 1
  fi
done

# Block maintenance. Items are delimited by <!-- item:NAME --> … <!-- /item -->.
#   merge BODY ITEMS FOOTER  splice the items (JSON [{name, md}]) into BODY's block,
#                            replacing same-name items and keeping the others
#   widen BODY               turn the block's ![alt](https://…) into width-capped <img>
#   pending BODY             print the block's ./relative references gh did not rewrite
body_tool() {
  IMG_WIDTH="$IMG_WIDTH" node -e '
    const fs = require("fs");
    const [mode, file, itemsJson, footer] = process.argv.slice(1);
    const START = "<!-- pr-media -->", END = "<!-- /pr-media -->";
    const ITEM = /<!-- item:(\S+) -->[\s\S]*?<!-- \/item -->/g;
    const body = fs.readFileSync(file, "utf8").replace(/\s+$/, "");
    const start = body.indexOf(START);
    const end = start === -1 ? -1 : body.indexOf(END, start);
    if (start !== -1 && end === -1) {
      console.error(`error: PR body has ${START} without ${END}; fix it by hand`);
      process.exit(1);
    }
    const block = start === -1 ? "" : body.slice(start, end + END.length);
    const splice = (next) =>
      start === -1 ? `${body}\n\n${next}\n` : body.slice(0, start) + next + body.slice(end + END.length) + "\n";
    if (mode === "pending") {
      if (start === -1) {
        console.log("(the pr-media block is missing)");
        process.exit(0);
      }
      for (const m of block.matchAll(/\]\((\.\/[^)]+)\)/g)) console.log(m[1]);
      process.exit(0);
    }
    if (mode === "widen") {
      const next = block.replace(
        /!\[([^\]]*)\]\((https:\/\/[^)\s]+)\)/g,
        (_, alt, src) => `<img src="${src}" alt="${alt.replace(/"/g, "&quot;")}" width="${process.env.IMG_WIDTH}">`,
      );
      fs.writeFileSync(file, splice(next));
      process.exit(0);
    }
    const items = new Map();
    for (const m of block.matchAll(ITEM)) items.set(m[1], m[0]);
    for (const { name, md } of JSON.parse(itemsJson)) items.set(name, `<!-- item:${name} -->\n${md}\n<!-- /item -->`);
    const next = [START, "### Screenshots & recordings", ...items.values(), footer, END].join("\n\n");
    fs.writeFileSync(file, splice(next));
  ' "$@"
}

# One JSON item per argument pair: name, markdown.
items_json() {
  node -e '
    const a = process.argv.slice(1), out = [];
    for (let i = 0; i < a.length; i += 2) out.push({ name: a[i], md: a[i + 1] });
    console.log(JSON.stringify(out));
  ' "$@"
}

if [[ "$BACKEND" == attach ]]; then
  ITEM_ARGS=()
  ATTACH_ARGS=()
  for f in "$TMP/out"/*; do
    file=$(basename "$f")
    ITEM_ARGS+=("${file%.*}" "**${file%.*}**"$'\n\n'"![${file%.*}](./$file)")
    ATTACH_ARGS+=(--attach "./$file")
  done
  "$GH" pr view "$PR" --json body -q .body >"$TMP/body.md"
  body_tool merge "$TMP/body.md" "$(items_json "${ITEM_ARGS[@]}")" "<sub>pr-media · gh --attach</sub>"
  (cd "$TMP/out" && "$GH" pr edit "$PR" -R "$REPO" --body-file "$TMP/body.md" "${ATTACH_ARGS[@]}" >/dev/null) ||
    echo "warning: gh reported a failed upload; checking what landed" >&2
  "$GH" pr view "$PR" --json body -q .body >"$TMP/body.md"
  pending=$(body_tool pending "$TMP/body.md")
  if [[ -n "$pending" ]]; then
    echo "error: these files did not upload and still point at local paths in PR #$PR:" >&2
    echo "$pending" >&2
    echo "  Re-run for them, or use PR_MEDIA_BACKEND=branch." >&2
    exit 1
  fi
  body_tool widen "$TMP/body.md"
  "$GH" pr edit "$PR" --body-file "$TMP/body.md" >/dev/null
  echo "attached $((${#ATTACH_ARGS[@]} / 2)) item(s) to PR #$PR (gh --attach)"
  exit 0
fi

fetch_tip() {
  if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    git fetch -q origin "+refs/heads/$BRANCH:$LOCAL_REF"
    git rev-parse "$LOCAL_REF"
  fi
}

COMMIT=""
for attempt in 1 2 3 4; do
  PARENT=$(fetch_tip)
  export GIT_INDEX_FILE="$TMP/index"
  rm -f "$GIT_INDEX_FILE"
  if [[ -n "$PARENT" ]]; then git read-tree "$PARENT"; else git read-tree --empty; fi
  for f in "$TMP/out"/*; do
    blob=$(git hash-object -w "$f")
    git update-index --add --cacheinfo "100644,$blob,$(basename "$f")"
  done
  TREE=$(git write-tree)
  unset GIT_INDEX_FILE
  if [[ -n "$PARENT" && "$TREE" == "$(git rev-parse "$PARENT^{tree}")" ]]; then
    echo "nothing new: $BRANCH already holds these files"
    COMMIT=$PARENT
    break
  fi
  COMMIT=$(git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "PR #$PR media")
  if out=$(git push -q origin "$COMMIT:refs/heads/$BRANCH" 2>&1); then
    break
  fi
  # Only a lost race is worth retrying; auth and permission errors are not.
  if ! grep -qE 'non-fast-forward|fetch first' <<<"$out"; then
    echo "error: push to $BRANCH failed:" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "push lost a race (attempt $attempt), retrying"
  COMMIT=""
  sleep $((attempt * 2))
done
[[ -n "$COMMIT" ]] || { echo "error: could not push to $BRANCH" >&2; exit 1; }

url() { echo "https://github.com/$REPO/blob/$COMMIT/$1?raw=true"; }

# Describe what the commit holds, not just this run's files.
FILES=$(git ls-tree --name-only "$COMMIT")
ITEM_ARGS=()
while IFS= read -r file; do
  base=${file%.*}
  ext=${file##*.}
  case "$ext" in
    mp4)
      # A bare MP4 (no GIF preview) is a leftover from an older run; link it.
      grep -qx "$base.gif" <<<"$FILES" || ITEM_ARGS+=("$base" "**$base** · [MP4]($(url "$file"))")
      continue
      ;;
    gif)
      if grep -qx "$base.mp4" <<<"$FILES"; then
        ITEM_ARGS+=("$base" "**$base** · [MP4]($(url "$base.mp4"))"$'\n\n'"<a href=\"$(url "$base.mp4")\"><img src=\"$(url "$file")\" width=\"$IMG_WIDTH\"></a>")
        continue
      fi
      ;;
    png | jpg | jpeg | webp) ;;
    *) continue ;;
  esac
  ITEM_ARGS+=("$base" "**$base**"$'\n\n'"<img src=\"$(url "$file")\" width=\"$IMG_WIDTH\">")
done <<<"$FILES"
FOOTER="<sub>pr-media · branch \`$BRANCH\` @ ${COMMIT:0:7}</sub>"

if ((EDIT_BODY == 0)); then
  : >"$TMP/body.md"
  body_tool merge "$TMP/body.md" "$(items_json "${ITEM_ARGS[@]}")" "$FOOTER"
  sed '/<!-- pr-media -->/,$!d' "$TMP/body.md"
  exit 0
fi

"$GH" pr view "$PR" --json body -q .body >"$TMP/body.md"
body_tool merge "$TMP/body.md" "$(items_json "${ITEM_ARGS[@]}")" "$FOOTER"
"$GH" pr edit "$PR" --body-file "$TMP/body.md" >/dev/null
echo "attached $((${#ITEM_ARGS[@]} / 2)) item(s) to PR #$PR ($BRANCH @ ${COMMIT:0:7})"
