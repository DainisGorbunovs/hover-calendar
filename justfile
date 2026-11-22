# Build and sign the macOS app bundle.
build:
    ./scripts/build-app.sh

# Build and launch Menu Calendar.
run: build
    if [ -n "${WEATHERKIT_PROFILE:-}" ]; then open ".build/Menu Calendar Weather.app"; else open ".build/Menu Calendar.app"; fi
