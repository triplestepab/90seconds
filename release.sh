#!/bin/bash
set -euo pipefail

printf 'Release workflow: bump version, commit, push main, then create and push the version tag.\n'

if [[ $(git branch --show-current) != main ]]; then
    printf 'Run releases from the main branch.\n' >&2
    exit 1
fi

version_file=90Seconds.xcodeproj/project.pbxproj
version=$(./bump.sh)

git commit --only -m "Release $version" -- "$version_file"
git push --no-follow-tags origin main
git tag "$version"
git push --no-follow-tags origin "refs/tags/$version"
