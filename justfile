# Build and sign the macOS app bundle.
build:
    ./scripts/build-app.sh

# Build and launch Menu Calendar.
run: build
    open ".build/Menu Calendar.app"
