#!/bin/sh
set -eu

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

build_dir="$project_dir/.build"
app_dir="$build_dir/Menu Calendar.app"
weather_profile=${WEATHERKIT_PROFILE:-}
identity=${CODE_SIGN_IDENTITY:--}

if [ -n "$weather_profile" ]; then
    if [ "$identity" = "-" ]; then
        printf '%s\n' 'Set CODE_SIGN_IDENTITY to the signing identity that matches WEATHERKIT_PROFILE.' >&2
        exit 1
    fi
    app_dir="$build_dir/Menu Calendar Weather.app"
    mkdir -p "$build_dir"
    profile_plist=$(mktemp "$build_dir/weatherkit-profile.XXXXXX")
    trap 'rm -f "$profile_plist"' EXIT
    /usr/bin/security cms -D -i "$weather_profile" > "$profile_plist"
    profile_weather=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.weatherkit' "$profile_plist")
    if [ "$profile_weather" != true ]; then
        printf '%s\n' 'WEATHERKIT_PROFILE must authorize WeatherKit.' >&2
        exit 1
    fi
    application_identifier=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist")
    team_identifier=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")
    case "$application_identifier" in
        ?*.?*) bundle_identifier=${application_identifier#*.} ;;
        *) printf '%s\n' 'WEATHERKIT_PROFILE must be an explicit macOS app profile.' >&2; exit 1 ;;
    esac
    case "$application_identifier" in
        *[!A-Za-z0-9.-]*) printf '%s\n' 'WEATHERKIT_PROFILE must have an explicit bundle identifier.' >&2; exit 1 ;;
    esac
fi

export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"

swift build --configuration release --cache-path "$build_dir/cache"
bin_dir=$(swift build --configuration release --show-bin-path --cache-path "$build_dir/cache")

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 755 "$bin_dir/MenuCalendar" "$app_dir/Contents/MacOS/MenuCalendar"
cp -R "$project_dir/Sources/MenuCalendar/EarthTextures" "$app_dir/Contents/Resources/"
install -m 644 "$project_dir/Sources/MenuCalendar/UKBankHolidays.json" "$app_dir/Contents/Resources/UKBankHolidays.json"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
if [ -n "$weather_profile" ]; then
    /usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$app_dir/Contents/Info.plist"
    install -m 644 "$weather_profile" "$app_dir/Contents/embedded.provisionprofile"
    entitlements="$build_dir/weatherkit.entitlements"
    /usr/bin/plutil -create xml1 "$entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.weatherkit bool true' "$entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $application_identifier" "$entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team_identifier" "$entitlements"
    codesign --force --sign "$identity" --entitlements "$entitlements" "$app_dir"
else
    codesign --force --sign "$identity" "$app_dir"
fi
printf '%s\n' "$app_dir"
