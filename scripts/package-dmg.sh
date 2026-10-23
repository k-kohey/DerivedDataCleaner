#!/bin/bash
set -euo pipefail

if [[ $# != 2 || ! -d "$1/Contents" ]]; then
  echo "Usage: $0 /path/to/DerivedDataCleaner.app /path/to/output.dmg" >&2
  exit 1
fi

app_path="$1"
dmg_path="$2"
# Refuse to overwrite an existing release artifact.
[[ ! -e "$dmg_path" ]]
codesign --verify --deep --strict "$app_path"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/deriveddata-dmg.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
ditto "$app_path" "$staging_dir/DerivedDataCleaner.app"
ln -s /Applications "$staging_dir/Applications"
mkdir -p "$(dirname "$dmg_path")"
hdiutil create -volname "DerivedData Cleaner" -srcfolder "$staging_dir" \
  -format UDZO -fs HFS+ "$dmg_path"
hdiutil verify "$dmg_path"
