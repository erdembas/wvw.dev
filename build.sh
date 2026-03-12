#!/usr/bin/env bash
set -euo pipefail

STORES_FILE="stores.json"
CATEGORIES_FILE="categories.json"
FEATURED_FILE="featured.json"
OUTPUT="apps.json"
TMP_DIR=$(mktemp -d)

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

stores=$(jq -r '.[]' "$STORES_FILE")
allowed_cats=$(jq -r '.[].id' "$CATEGORIES_FILE")
categories=$(cat "$CATEGORIES_FILE")
featured=$(cat "$FEATURED_FILE")
all_apps="[]"

for entry in $stores; do
  echo -n "Fetching $entry... "

  if [[ "$entry" =~ ^https?:// ]]; then
    raw_url="$entry"
    owner=$(echo "$entry" | sed -E 's|.*/([^/]+)/[^/]+$|\1|' || echo "unknown")
    source_id="$entry"
  else
    raw_url="https://raw.githubusercontent.com/${entry}/HEAD/apps.json"
    owner=$(echo "$entry" | cut -d/ -f1)
    source_id="$entry"
  fi

  tmp_file="$TMP_DIR/$(echo "$entry" | tr '/:.' '_').json"

  if ! curl -sf "$raw_url" ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} -o "$tmp_file"; then
    echo "FAILED"
    continue
  fi

  app_count=$(jq '.apps | length' "$tmp_file")
  store_name=$(jq -r '.store.name // "Unknown"' "$tmp_file")
  store_url=$(jq -r '.store.url // ""' "$tmp_file")
  developer=$(jq -r '.store.developer // "Unknown"' "$tmp_file")
  echo "OK ($app_count apps from $store_name by $developer)"

  apps_with_source=$(jq --arg source "$source_id" --arg owner "$owner" --arg dev "$developer" --arg store "$store_name" --arg storeUrl "$store_url" --argjson allowed "$(echo "$allowed_cats" | jq -R . | jq -s .)" '
    .apps | map(
      . + { _source: $source, _owner: $owner, _developer: $dev, _store: $store, _storeUrl: $storeUrl } |
      if .developer == null then .developer = $dev else . end |
      .category = [.category[] | select(. as $c | $allowed | index($c))]
    ) | map(select(.category | length > 0))
  ' "$tmp_file")
  all_apps=$(echo "$all_apps" "$apps_with_source" | jq -s '.[0] + .[1]')
done

unique_apps=$(echo "$all_apps" | jq 'unique_by(.id)')
total=$(echo "$unique_apps" | jq 'length')

echo ""
echo "Fetching live GitHub stats for $total apps..."

updated_apps="[]"
while IFS= read -r app_json; do
  github_url=$(echo "$app_json" | jq -r '.github // ""')
  app_name=$(echo "$app_json" | jq -r '.name')

  if [[ "$github_url" =~ github\.com/([^/]+/[^/]+) ]]; then
    repo_path="${BASH_REMATCH[1]}"
    echo -n "  $app_name ($repo_path)... "

    stats=$(curl -sf "https://api.github.com/repos/$repo_path" \
      ${GITHUB_TOKEN:+-H "Authorization: token $GITHUB_TOKEN"} 2>/dev/null) || stats=""

    if [ -n "$stats" ]; then
      stars=$(echo "$stats" | jq '.stargazers_count // 0')
      forks=$(echo "$stats" | jq '.forks_count // 0')
      echo "★ $stars  ⑂ $forks"
      app_json=$(echo "$app_json" | jq --argjson s "$stars" --argjson f "$forks" '.stars = $s | .forks = $f')
    else
      echo "SKIPPED (API error)"
    fi
  fi

  updated_apps=$(echo "$updated_apps" "[$app_json]" | jq -s '.[0] + .[1]')
done < <(echo "$unique_apps" | jq -c '.[]')

jq -n \
  --argjson apps "$updated_apps" \
  --argjson categories "$categories" \
  --argjson featured "$featured" \
  '{
    store: {
      name: "World Vibe Web",
      developer: "Community",
      tagline: "The distributed app store for vibe-coded projects.",
      github: "https://github.com/f/wvw.dev"
    },
    featured: $featured,
    categories: $categories,
    apps: $apps
  }' > "$OUTPUT"

rm -rf "$TMP_DIR"
echo ""
echo "Done. $total apps merged into $OUTPUT"
