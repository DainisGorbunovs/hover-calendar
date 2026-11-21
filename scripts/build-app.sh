#!/bin/sh
set -eu

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

build_dir="$project_dir/.build"
app_dir="$build_dir/Menu Calendar.app"
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"

swift build --configuration release --cache-path "$build_dir/cache"
bin_dir=$(swift build --configuration release --show-bin-path --cache-path "$build_dir/cache")

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 755 "$bin_dir/MenuCalendar" "$app_dir/Contents/MacOS/MenuCalendar"
cp -R "$project_dir/Sources/MenuCalendar/EarthTextures" "$app_dir/Contents/Resources/"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app_dir"
printf '%s\n' "$app_dir"
