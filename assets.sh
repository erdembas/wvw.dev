#!/usr/bin/env bash
set -euo pipefail

APPS_FILE="apps.json"
ICONS_DIR="assets/icons"
SHOWCASE_DIR="assets/showcase"
ICONS_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --icons-only) ICONS_ONLY=true ;;
  esac
done

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required."
  exit 1
fi

if [ ! -f "$APPS_FILE" ]; then
  echo "Error: $APPS_FILE not found. Run build.sh first."
  exit 1
fi

mkdir -p "$ICONS_DIR" "$SHOWCASE_DIR"

REPO_BASE="https://raw.githubusercontent.com/f/wvw.dev/master"
OUR_ICON_PREFIX="${REPO_BASE}/${ICONS_DIR}/"

# --- Remove our fallback icons for apps whose store owner added their own icon ---
echo "=== Checking for store-owner icon updates ==="

removed=0
for icon_file in "$ICONS_DIR"/*.jpg; do
  [ -f "$icon_file" ] || continue
  app_id=$(basename "$icon_file" .jpg)
  our_url="${OUR_ICON_PREFIX}${app_id}.jpg"

  current_icon=$(jq -r --arg id "$app_id" '.apps[] | select(.id == $id) | .icon // empty' "$APPS_FILE" | head -1)

  if [ -n "$current_icon" ] && [ "$current_icon" != "$our_url" ]; then
    echo "  $app_id — store owner set icon, removing our fallback"
    rm -f "$icon_file"
    removed=$((removed + 1))
  fi
done
echo "Removed $removed superseded fallback icons."

# --- Generate icons for apps without icons ---
echo ""
echo "=== Generating icons for apps without icons ==="

icon_count=0
while IFS= read -r app; do
  [ -z "$app" ] && continue
  app_id=$(echo "$app" | jq -r '.id')
  app_name=$(echo "$app" | jq -r '.name')
  app_subtitle=$(echo "$app" | jq -r '.subtitle // ""')
  app_category=$(echo "$app" | jq -r '(.category // [])[0] // "utilities"')
  app_platform=$(echo "$app" | jq -r '.platform // "App"')

  icon_file="$ICONS_DIR/${app_id}.jpg"

  if [ -f "$icon_file" ]; then
    echo "  $app_name — already cached"
    continue
  fi

  if [ -z "${FAL_AI_KEY:-}" ]; then
    echo "  $app_name — SKIPPED (no FAL_AI_KEY)"
    continue
  fi

  echo -n "  $app_name — generating... "

  prompt="A square app icon that fills the entire canvas edge-to-edge with ZERO padding, ZERO margin, ZERO border, NO empty space around the edges. The icon for \"${app_name}\" — ${app_subtitle}. Category: ${app_category}. A bold symbolic graphic on a solid or gradient color background that extends to every pixel of the image boundary. Style: iOS/macOS app icon, vibrant colors, simple centered symbol. No text, no letters, no words. The background color must touch all four edges completely."

  response=$(curl -s --max-time 60 -X POST "https://fal.run/fal-ai/nano-banana" \
    -H "Authorization: Key ${FAL_AI_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$prompt" '{
      prompt: $p,
      image_size: "square",
      num_images: 1
    }')" 2>/dev/null) || response=""

  img_url=$(echo "$response" | jq -r '.images[0].url // empty' 2>/dev/null) || img_url=""

  if [ -n "$img_url" ]; then
    if curl -sL "$img_url" -o "${icon_file}.tmp"; then
      if magick "${icon_file}.tmp" -resize 512x512^ -gravity center -extent 512x512 -quality 85 "$icon_file" 2>/dev/null; then
        echo "OK"
        icon_count=$((icon_count + 1))
      else
        echo "CONVERT FAILED"
      fi
    else
      echo "DOWNLOAD FAILED"
    fi
    rm -f "${icon_file}.tmp"
  else
    echo "API FAILED"
  fi
done < <(jq -c '.apps[] | select(.icon == null or .icon == "")' "$APPS_FILE")

echo "Generated $icon_count new icons."

# --- Update apps.json with generated icon URLs ---
echo ""
echo "=== Updating apps.json with generated icon URLs ==="

updated=0
for icon_file in "$ICONS_DIR"/*.jpg; do
  [ -f "$icon_file" ] || continue
  app_id=$(basename "$icon_file" .jpg)
  icon_url="${OUR_ICON_PREFIX}${app_id}.jpg"

  current_icon=$(jq -r --arg id "$app_id" '.apps[] | select(.id == $id) | .icon // empty' "$APPS_FILE" | head -1)
  if [ -z "$current_icon" ] || [ "$current_icon" = "$icon_url" ]; then
    jq --arg id "$app_id" --arg url "$icon_url" '
      .apps = [.apps[] | if .id == $id then .icon = $url | .iconStyle = {"scale": 1, "objectFit": "cover", "borderRadius": "22%"} else . end]
    ' "$APPS_FILE" > "${APPS_FILE}.tmp" && mv "${APPS_FILE}.tmp" "$APPS_FILE"
    if [ -z "$current_icon" ]; then
      echo "  $app_id — icon URL set"
      updated=$((updated + 1))
    fi
  fi
done

echo "Updated $updated app icon URLs."

# --- Cache showcase images (skip if --icons-only) ---
if [ "$ICONS_ONLY" = true ]; then
  echo ""
  echo "Skipping showcase caching (--icons-only mode)."
  echo "Done."
  exit 0
fi

echo ""
echo "=== Caching showcase images ==="

if [ ! -f "showcase.json" ]; then
  echo "No showcase.json found, skipping."
else
  showcase_count=0
  while IFS= read -r pick; do
    [ -z "$pick" ] && continue
    app_id=$(echo "$pick" | jq -r '.id')
    img_url=$(echo "$pick" | jq -r '.showcase_image // empty')

    [ -z "$img_url" ] && continue
    echo "$img_url" | grep -q "^${REPO_BASE}" && continue

    cache_file="$SHOWCASE_DIR/${app_id}.jpg"

    if [ -f "$cache_file" ]; then
      echo "  $app_id — already cached"
      continue
    fi

    echo -n "  $app_id — downloading... "
    if curl -sL "$img_url" -o "${cache_file}.tmp" 2>/dev/null; then
      magick "${cache_file}.tmp" -quality 80 "$cache_file" 2>/dev/null && \
      rm -f "${cache_file}.tmp" && \
      echo "OK ($(du -h "$cache_file" | awk '{print $1}'))" && \
      showcase_count=$((showcase_count + 1))
    else
      rm -f "${cache_file}.tmp"
      echo "FAILED"
    fi
  done < <(jq -c '.picks[]' showcase.json)

  echo "Cached $showcase_count new showcase images."
fi

# --- Update showcase.json with cached image URLs ---
for cache_file in "$SHOWCASE_DIR"/*.jpg; do
  [ -f "$cache_file" ] || continue
  app_id=$(basename "$cache_file" .jpg)
  cache_url="${REPO_BASE}/${SHOWCASE_DIR}/${app_id}.jpg"

  if [ -f "showcase.json" ]; then
    jq --arg id "$app_id" --arg url "$cache_url" '
      .picks = [.picks[] | if .id == $id then .showcase_image = $url else . end] |
      .highlights = [.highlights[] | if .id == $id then .showcase_image = $url else . end]
    ' showcase.json > showcase.json.tmp && mv showcase.json.tmp showcase.json
  fi
done

echo ""
echo "Done."
