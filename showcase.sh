#!/usr/bin/env bash
set -euo pipefail

APPS_FILE="apps.json"
CATEGORIES_FILE="categories.json"
OUTPUT="showcase.json"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

if [ ! -f "$APPS_FILE" ]; then
  echo "Error: $APPS_FILE not found. Run build.sh first."
  exit 1
fi

categories=$(jq -r '.[] | select(.id != "all") | .id' "$CATEGORIES_FILE")
apps_json=$(jq '.apps' "$APPS_FILE")

showcase="[]"

for cat in $categories; do
  candidates=$(echo "$apps_json" | jq --arg c "$cat" '[.[] | select(.category != null and (.category | index($c)))]')
  count=$(echo "$candidates" | jq 'length')

  if [ "$count" -eq 0 ]; then
    continue
  fi

  if [ "$count" -le 2 ]; then
    picked=$(echo "$candidates" | jq '[.[] | { id: .id, name: .name, subtitle: .subtitle, icon: .icon, iconStyle: .iconStyle, iconEmoji: .iconEmoji, screenshot: (if .screenshots and (.screenshots | length) > 0 then .screenshots[0] else null end), category: $c, platform: .platform, stars: (.stars // 0) }]' --arg c "$cat")
  else
    picked=$(echo "$candidates" | jq --arg c "$cat" '
      [., length] as [$arr, $len] |
      [(now * 1000 | floor % $len), ((now * 1000 | floor + 7) % $len)] as [$i1, $i2] |
      (if $i1 == $i2 then ($i1 + 1) % $len else $i2 end) as $i2fixed |
      [$arr[$i1], $arr[$i2fixed]] |
      map({ id: .id, name: .name, subtitle: .subtitle, icon: .icon, iconStyle: .iconStyle, iconEmoji: .iconEmoji, screenshot: (if .screenshots and (.screenshots | length) > 0 then .screenshots[0] else null end), category: $c, platform: .platform, stars: (.stars // 0) })
    ')
  fi

  showcase=$(echo "$showcase" "$picked" | jq -s '.[0] + .[1]')
done

# Pick 2 highlight apps: prefer those with screenshots and high stars
highlights=$(echo "$showcase" | jq '
  [.[] | select(.screenshot != null)] | sort_by(-.stars) |
  if length >= 2 then [.[0], .[1]]
  elif length == 1 then [.[0]]
  else []
  end
')

# Generate AI images for showcase picks via fal.ai
STYLES=(
  "3D rendered objects floating on a gradient background, glossy and tactile, soft shadows, like a modern app store editorial card"
  "Isometric low-poly scene, vibrant colors, clean geometric shapes, playful and modern"
  "Flat vector illustration with bold colors and simple shapes, editorial magazine style"
  "Neon-lit objects on a dark background, cyberpunk-inspired but clean and elegant"
  "Watercolor-style digital painting, soft edges, warm palette, artistic and inviting"
  "Paper cut-out layered scene, depth and shadows, craft-style with vivid colors"
)

generate_image() {
  local name="$1"
  local subtitle="$2"
  local platform="$3"
  local category="$4"
  local index="$5"
  local icon_url="$6"

  local style="${STYLES[$((index % ${#STYLES[@]}))]}"

  local prompt="App store promotional banner for \"${name}\": ${subtitle}. Create a beautiful wide banner scene that represents this app. Place the app icon prominently in the composition and build a rich, thematic environment around it with relevant objects and symbols. Style: ${style}. Wide 16:9 composition. No text, no words, no letters."

  local response
  if [ -n "$icon_url" ] && [ "$icon_url" != "null" ]; then
    response=$(curl -s --max-time 60 -X POST "https://fal.run/fal-ai/nano-banana-2/edit" \
      -H "Authorization: Key ${FAL_AI_KEY}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg p "$prompt" --arg img "$icon_url" '{
        prompt: $p,
        image_urls: [$img],
        aspect_ratio: "16:9",
        num_images: 1
      }')" 2>/dev/null) || echo ""
  else
    response=$(curl -s --max-time 60 -X POST "https://fal.run/fal-ai/nano-banana-2" \
      -H "Authorization: Key ${FAL_AI_KEY}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg p "$prompt" '{
        prompt: $p,
        aspect_ratio: "16:9",
        num_images: 1
      }')" 2>/dev/null) || echo ""
  fi

  if [ -n "$response" ]; then
    echo "$response" | jq -r '.images[0].url // .data.images[0].url // empty' 2>/dev/null || echo ""
  fi
}

if [ -n "${FAL_AI_KEY:-}" ]; then
  echo ""
  echo "Generating AI images for showcase picks..."

  updated_showcase="[]"
  img_index=0
  while IFS= read -r pick; do
    app_name=$(echo "$pick" | jq -r '.name')
    app_subtitle=$(echo "$pick" | jq -r '.subtitle')
    app_platform=$(echo "$pick" | jq -r '.platform')
    app_category=$(echo "$pick" | jq -r '.category')
    app_icon=$(echo "$pick" | jq -r '.icon // empty')

    echo -n "  $app_name... "
    img_url=$(generate_image "$app_name" "$app_subtitle" "$app_platform" "$app_category" "$img_index" "$app_icon")
    img_index=$((img_index + 1))

    if [ -n "$img_url" ]; then
      pick=$(echo "$pick" | jq --arg u "$img_url" '.showcase_image = $u')
      echo "OK"
    else
      echo "SKIPPED"
    fi

    updated_showcase=$(echo "$updated_showcase" | jq --argjson p "$pick" '. + [$p]')
  done < <(echo "$showcase" | jq -c '.[]')

  showcase="$updated_showcase"

  # Re-pick highlights with updated data
  highlights=$(echo "$showcase" | jq '
    [.[] | select(.showcase_image != null or .screenshot != null)] | sort_by(-.stars) |
    if length >= 2 then [.[0], .[1]]
    elif length == 1 then [.[0]]
    else []
    end
  ')

  echo "AI image generation complete."
else
  echo "FAL_AI_KEY not set, skipping AI image generation."
fi

jq -n --argjson showcase "$showcase" --argjson highlights "$highlights" '{
  generated_at: (now | todate),
  highlights: $highlights,
  picks: $showcase
}' > "$OUTPUT"

total=$(echo "$showcase" | jq 'length')
hl=$(echo "$highlights" | jq 'length')
echo "Done. $total showcase picks ($hl highlights) written to $OUTPUT"
