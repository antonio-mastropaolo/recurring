#!/bin/bash
# Regenerates RecurringApp/Assets.xcassets/AppIcon.appiconset from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
set_dir=RecurringApp/Assets.xcassets/AppIcon.appiconset
mkdir -p "$set_dir"
tmp=$(mktemp -d)
swift scripts/make-icon.swift "$tmp/icon-1024.png"
images=""
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  pt=${spec%:*}; scale=${spec#*:}; px=$((pt * scale))
  name="icon_${pt}x${pt}@${scale}x.png"
  sips -z $px $px "$tmp/icon-1024.png" --out "$set_dir/$name" >/dev/null
  images+="{\"idiom\":\"mac\",\"size\":\"${pt}x${pt}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
done
echo "{\"images\":[${images%,}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$set_dir/Contents.json"
rm -rf "$tmp"
echo "icon set written to $set_dir"
