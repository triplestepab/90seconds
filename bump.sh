#!/bin/bash
set -euo pipefail

version_file=90Seconds.xcodeproj/project.pbxproj
current_version=$(awk '$1 == "MARKETING_VERSION" && $2 == "=" { sub(/;$/, "", $3); print $3; exit }' "$version_file")
patch=${current_version##*.}
version="${current_version%.*}.$((10#$patch + 1))"

sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*)[0-9.]+;/\\1$version;/" "$version_file"
printf '%s\n' "$version"
