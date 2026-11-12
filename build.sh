#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
app_path="$project_dir/dist/90 seconds.app"

./bump.sh

xcodebuild -project "$project_dir/90Seconds.xcodeproj" -scheme 90Seconds \
    -derivedDataPath "$project_dir/.build" -configuration Release CONFIGURATION_BUILD_DIR="$project_dir/dist" build

test -d "$app_path" && test -x "$app_path/Contents/MacOS/90 seconds"
/usr/bin/codesign --force --sign "90 Seconds Local Code Signing" --timestamp=none "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
printf 'Successfully built %s\n' "$app_path"
