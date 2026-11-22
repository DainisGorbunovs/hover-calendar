#!/bin/sh
# Render the globe and its weather overlays to PNGs, without needing a
# WeatherKit entitlement. Pass an output directory, or take the default.
set -eu

project_dir=$(cd "$(dirname "$0")/.." && pwd)
sources="$project_dir/Sources/MenuCalendar"
output=${1:-"$project_dir/.build/globe-previews"}
build_dir="$project_dir/.build"

mkdir -p "$build_dir"
swiftc -O \
    "$sources/WeatherColorScale.swift" \
    "$sources/AppleWeatherField.swift" \
    "$sources/AppleWeatherStore.swift" \
    "$sources/WindParticles.swift" \
    "$sources/WorldClockLocation.swift" \
    "$sources/SolarPosition.swift" \
    "$sources/GlobeCamera.swift" \
    "$sources/GlobeMetalView.swift" \
    "$project_dir/tools/render-globe.swift" \
    -parse-as-library \
    -o "$build_dir/render-globe"

"$build_dir/render-globe" "$sources/EarthTextures" "$output"
