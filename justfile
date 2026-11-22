# Build and sign the macOS app bundle.
build:
    ./scripts/build-app.sh

# Build and launch Menu Calendar.
run: build
    if [ -n "${WEATHERKIT_PROFILE:-}" ]; then open ".build/Menu Calendar Weather.app"; else open ".build/Menu Calendar.app"; fi

# Render the globe and its weather overlays to PNGs, no entitlement needed.
preview output="":
    ./tools/render-globe.sh {{output}}

# Rewrite the colour scales from Apple Weather's cached overlay metadata.
colour-scales:
    ./tools/extract-weather-color-scales.py
