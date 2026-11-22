# Menu Calendar

Hover over the built-in macOS menu-bar date and time to see the calendar, daylight globe, and six world clocks together. The calendar stays open as you move into it, so you can browse with the arrows or return with **Today**. Click the month heading to jump directly to another month or type a year. Bring two fingers together over the calendar to step from dates to months to years. Spread your fingers to go back one level. Click a date to keep its details in the footer. The grid highlights today, shades weekend columns, and marks public holidays with a teal dot. Hover over a date for a raised highlight and its date or holiday name. The calendar shows the next holiday in the month when available. Week numbers, the first day of the week, and weekends follow your Mac’s calendar and regional settings.

The world-clock strip shows London, New York, Chicago, San Francisco, Riga, and Taipei. The clocks run from earliest to latest local date and time and refresh each minute and show 24-hour local time and UTC offsets, with time-zone abbreviations where available. A city’s date appears when it differs from yours. Pause over a city in the strip to fly to it. Long flights pull back for the turn and then zoom in on arrival. The daylight strip shows local sunrise, sunset, and the city’s position in its day. Clicking a city focuses it immediately.

The globe updates its solar lighting every minute. It renders terrain, ocean reflections, cloud shadows, twilight, and city lights. The cloud layer uses a [NASA satellite composite](https://science.nasa.gov/earth/earth-observatory/the-blue-marble-true-color-global-imagery-at-1km-resolution/) with lighting calculated for the current time. It works offline with satellite composites from [NASA Blue Marble Next Generation](https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-topography/) and [NASA Black Marble](https://science.nasa.gov/earth/earth-observatory/earth-at-night/maps/). The Sun’s position is calculated using [U.S. Naval Observatory solar coordinates](https://aa.usno.navy.mil/faq/sun_approx) and [sidereal time](https://aa.usno.navy.mil/faq/GAST).

Imagery credits go to NASA Earth Observatory and Reto Stöckli (Blue Marble) and to Joshua Stevens using Suomi NPP VIIRS data from Miguel Román, NASA GSFC (Black Marble).

The opening view centers on the city matching your Mac’s time zone when one is available. Choose **… → Use My Location…** and grant macOS location access to center on your actual area and show its daylight times. The app keeps the latest fix in memory while running.

Choose **US**, **E&W**, **SCO**, or **NI** in the calendar footer to change which holidays you see. The default follows the Mac’s region for the United States and United Kingdom. The U.S. calendar includes nationwide federal holidays and their observed weekdays. The UK schedules include officially published substitute days and currently cover 2019–2028. [U.S. Office of Personnel Management](https://www.opm.gov/policy-data-oversight/pay-leave/federal-holidays/) · [GOV.UK bank holidays](https://www.gov.uk/bank-holidays)

## Build and run

Use macOS 13 or later with Xcode or the Swift command-line tools.

With `just` installed, run `just build` to build the app or `just run` to build and launch it. You can also use the build script directly.

```sh
./scripts/build-app.sh
open ".build/Menu Calendar.app"
```

Hover over the built-in date and time or the space directly above it. Clicking the clock still opens Notification Center. Click **…** over the globe and choose **Quit Menu Calendar** to exit.

## Apple Weather layers

Open **… → Weather Layers** to choose **Temperature**, **Precipitation**, or **Wind**. The globe zooms to the selected city’s region and renders a sampled forecast from Apple WeatherKit. Wind streaks follow the sampled wind vectors. The weather badge shows the update time and links to Apple Weather’s data attribution.

Live weather uses a signed macOS build with an Apple Developer Program profile for an explicit App ID that has WeatherKit enabled in both App Services and App Capabilities. Set `WEATHERKIT_PROFILE` to the macOS provisioning profile and `CODE_SIGN_IDENTITY` to its signing identity, then run `just run`. This creates `.build/Menu Calendar Weather.app` using the bundle identifier from the profile. The standard local build shows the WeatherKit setup message when a weather layer is selected. [Apple WeatherKit setup](https://developer.apple.com/help/account/services/weatherkit/)

### Colour scales

The temperature and precipitation layers use Apple Weather's own map-overlay colour scales, so a reading shows the same colour here as it does in Weather. Apple Weather downloads those scales and caches them unencrypted in its own container on this Mac, at `~/Library/Containers/com.apple.weather/Data/Library/Caches/MapOverlays/`. Opening Weather once and showing the map writes that cache. Each scale is a list of stops pairing a physical value with an RGBA colour, interpolated linearly in between.

Temperature runs from −40 °C to 55 °C across fourteen stops, deep violet through blue, cyan and yellow to dark red. Precipitation runs to 205 mm/h across eight stops, the lightest almost fully transparent so a drizzle tints the globe instead of covering it.

The globe stores each reading across exactly the range its scale covers, taken from the scale itself so the two cannot drift apart, and clamps rather than wraps past either end. Precipitation follows a logarithmic curve, so the ordinary millimetre or two keeps most of the ramp instead of being crushed against one end by the cloudburst at the top of the scale.

Apple builds its wind colours in code rather than publishing them in that cache, so the wind ramp is this app's own. It is shaped like the others and can be replaced without touching the renderer.

Run `tools/extract-weather-color-scales.py` to rewrite `Sources/MenuCalendar/WeatherColorScale.swift` from the current cache, or `--list` to print every scale it finds, including the air quality scales for twenty countries. The script only reads the cache; it fetches nothing and changes nothing outside this project.


## Trackpad gestures

Over the calendar, swipe horizontally with two fingers to pull the next or previous month into view. The page snaps into place when you commit the swipe.

Over the globe, drag or use two fingers to orbit the Earth, then release to let it coast. Pinch over the globe to zoom into the spot beneath the pointer. The popup temporarily takes app focus while the pointer is over the calendar or globe and returns it when you move away. A double-click zooms into that spot too. Globe zoom goes up to 7.2×. Hover over the city control to open the picker, then pause on a name for a closer look, or click it to focus immediately. Choose **Reset Globe** in the options menu to return to the default 2.2× view. Pinch together to pull back for the full Earth.

Supported Force Touch trackpads give a small tap when a month or city selection commits and when zoom snaps to its limits.

## Clock position

The app uses pointer coordinates and the menu bar’s bounds. It requires no Accessibility or Screen Recording permission. The default hover area is 145 points wide and ends 20 points from the right edge, matching the tested macOS 27 clock layout. If your clock format or menu bar layout changes, set the width and right inset in points, then relaunch the app.

```sh
defaults write local.menucalendar.app ClockHoverWidth -float 145
defaults write local.menucalendar.app ClockHoverRightInset -float 20
```

The build script signs the app locally. Set `CODE_SIGN_IDENTITY` when building if you have a signing identity you want to reuse.
