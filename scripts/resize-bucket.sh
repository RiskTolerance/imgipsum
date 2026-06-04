#!/usr/bin/env bash
#
# Resize R2 bucket originals to 1600px on the longest edge, in place.
# Source of 1102 errors = oversized originals; transform decodes them and
# blows the worker CPU/memory budget. Cap longest edge at max(SIZES)=1600.
#
# Usage:
#   ./scripts/resize-bucket.sh                       # apply, no backup
#   BACKUP_DIR=./backup-originals ./scripts/...       # save each original locally before overwrite
#   DRY_RUN=1 ./scripts/resize-bucket.sh             # report only, no uploads / no backup
#
# Requires: wrangler (logged in), ImageMagick `magick`. Operates on REMOTE R2.

set -euo pipefail

BUCKET="imgipsum"
MAX_EDGE=1600
QUALITY=85
DRY_RUN="${DRY_RUN:-0}"
BACKUP_DIR="${BACKUP_DIR:-}"

# Collections + object counts — mirror COUNTS in src/index.ts.
# "collection count" pairs (bash 3.2 has no associative arrays).
COUNTS="
portraits 20
food 20
landscapes 20
architecture 20
pets/dogs 20
pets/cats 20
pets/other 5
"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

resized=0 skipped=0 missing=0 total=0

while read -r coll count; do
  [[ -z "$coll" ]] && continue
  for ((i = 1; i <= count; i++)); do
    key="${coll}/${i}.jpg"
    total=$((total + 1))
    local_path="${WORK}/${key}"
    mkdir -p "$(dirname "$local_path")"

    # Pull original from remote R2
    if ! npx wrangler r2 object get "${BUCKET}/${key}" --file "$local_path" --remote >/dev/null 2>&1; then
      echo "MISSING  ${key}"
      missing=$((missing + 1))
      continue
    fi

    # Back up the untouched original locally before any overwrite
    if [[ -n "$BACKUP_DIR" && "$DRY_RUN" != "1" ]]; then
      bpath="${BACKUP_DIR}/${key}"
      mkdir -p "$(dirname "$bpath")"
      cp "$local_path" "$bpath"
    fi

    read -r w h < <(magick identify -format '%w %h\n' "$local_path" 2>/dev/null || echo "0 0") || true
    edge=$((w > h ? w : h))

    if [[ "$edge" -le "$MAX_EDGE" || "$edge" -eq 0 ]]; then
      echo "OK       ${key}  ${w}x${h}"
      skipped=$((skipped + 1))
      continue
    fi

    # Shrink longest edge to MAX_EDGE, preserve aspect, strip metadata
    out="${local_path}.resized.jpg"
    magick "$local_path" -resize "${MAX_EDGE}x${MAX_EDGE}>" -strip -quality "$QUALITY" "$out"
    read -r nw nh < <(magick identify -format '%w %h\n' "$out") || true

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "WOULD    ${key}  ${w}x${h} -> ${nw}x${nh}"
      resized=$((resized + 1))
      continue
    fi

    npx wrangler r2 object put "${BUCKET}/${key}" --file "$out" \
      --content-type image/jpeg --remote >/dev/null 2>&1
    echo "RESIZED  ${key}  ${w}x${h} -> ${nw}x${nh}"
    resized=$((resized + 1))
  done
done < <(echo "$COUNTS")

echo "----"
echo "total=${total} resized=${resized} ok=${skipped} missing=${missing} dry_run=${DRY_RUN}"
