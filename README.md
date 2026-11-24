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

Open **… → Weather Layers** to choose **Temperature**, **Precipitation**, or **Wind**. The globe zooms to the selected city’s region and draws Apple Weather’s forecast over it. The weather badge shows the reading at the city and credits Apple Weather.

The wind layer carries a few thousand particles on the forecast wind, each leaving a fading trail, the way Apple’s own wind map does: every frame dims the previous trails and draws each particle’s latest move on top. The trails are kept in the region’s own coordinates rather than on the screen, so orbiting or zooming the globe never smears them. A particle covers in one second the distance the wind would carry air in a few hours, so a breeze visibly crosses the region while calm air barely moves. With Reduce Motion on, the layer shows the trails from a moment of flow and holds them still.

The forecast comes from Apple in one of three ways, and the app uses the best one this Mac can offer.

**Weather’s own places, with no setup.** Apple’s weather service keeps the hourly forecast for every location saved in Weather up to date in the background, so Weather’s widgets stay current, and stores it unencrypted in `~/Library/Weather/weather-data.db`. The app reads that store directly; it makes no request of its own and needs no entitlement. Because the store holds one forecast per place rather than a map, the globe draws it as a halo around the city instead of pretending it covers the whole region. A city that Weather does not track says so on the badge; add it in Weather and it appears here within minutes. Each stored hour is a fixed-size record whose layout was worked out by comparing every field against its neighbours and against physics; the reader checks each record’s sea-level pressure before trusting it, so a change to that layout shows no weather rather than the wrong weather.

**A sampled grid, through Shortcuts.** Shortcuts’ Get Weather Forecast action runs under Shortcuts’ own WeatherKit entitlement, and Shortcuts is built to be scripted, so a shortcut can sample the region’s five-by-five grid for a build with no entitlement of its own. Run `tools/make-weather-shortcut.py`, sign the result with `shortcuts sign --mode anyone --input <file> --output "Menu Calendar Weather.shortcut"`, and open it to add **Menu Calendar Weather** to Shortcuts. The app hands it one Apple Maps link per grid point (Shortcuts will not turn plain text into a place, but turns a Maps link into a placemark at exactly its coordinate) and gets back each point’s next thirteen hours, converted by Shortcuts itself to °C, mm and km/h at full precision whatever the Mac’s region. A grid takes about ten seconds and is kept for an hour; while it loads, Weather’s halo for the city shows if it has one. With the shortcut added, every city gets a grid, including ones Weather does not track.

**A sampled grid, with WeatherKit.** A signed build with the WeatherKit entitlement instead asks for a five-by-five grid of forecasts across the region, so temperature gradients and rain bands show their shape. This needs an Apple Developer Program profile for an explicit App ID that has WeatherKit enabled in both App Services and App Capabilities; a locally declared entitlement alone is refused by Apple’s servers. Set `WEATHERKIT_PROFILE` to the macOS provisioning profile and `CODE_SIGN_IDENTITY` to its signing identity, then run `just run`. This creates `.build/Menu Calendar Weather.app` using the bundle identifier from the profile. [Apple WeatherKit setup](https://developer.apple.com/help/account/services/weatherkit/)

Either way, each place brings back its hourly forecast, so one read covers the next thirteen hours. The globe draws the two hours the current moment falls between and blends them in stored units before any colour is chosen, the way Apple's own tweening pass does, so the overlay drifts with the clock instead of stepping on the hour. The badge blends the same way, so the number and the colours always agree.

### Colour scales

The temperature and precipitation layers use Apple Weather's own map-overlay colour scales, so a reading shows the same colour here as it does in Weather. Apple Weather downloads those scales and caches them unencrypted in its own container on this Mac, at `~/Library/Containers/com.apple.weather/Data/Library/Caches/MapOverlays/`. Opening Weather once and showing the map writes that cache. Each scale is a list of stops pairing a physical value with an RGBA colour, interpolated linearly in between.

Temperature runs from −40 °C to 55 °C across fourteen stops, deep violet through blue, cyan and yellow to dark red. Precipitation runs to 205 mm/h across eight stops, the lightest almost fully transparent so a drizzle tints the globe instead of covering it.

The globe stores each reading across exactly the range its scale covers, taken from the scale itself so the two cannot drift apart, and clamps rather than wraps past either end. Precipitation follows a logarithmic curve, so the ordinary millimetre or two keeps most of the ramp instead of being crushed against one end by the cloudburst at the top of the scale.

Apple builds its wind colours in code rather than publishing them in that cache, so the wind ramp is copied from WeatherMaps itself: thirteen stops on the Beaufort thresholds, defined in m/s over 0–70 m/s, deepening from `#0078BD` in calm air to `#009DE0` at force 12 (117 km/h) and flat from there. Spread over that range they rebuild, byte for byte, the colour map Weather uploads to the GPU, which was captured as it went up. Apple draws that blue opaque under coastlines and labels; the globe has neither, so it lets the land show faintly through.

The same capture confirmed the other ramps' ranges: Weather's temperature colour map is exactly Apple's published stops spread over −40…55 °C, which is the range the globe stores temperature over.

Run `just preview` to draw the globe and each weather overlay to PNGs under `.build/globe-previews`, using a made-up forecast that sweeps every scale from end to end. It drives the real renderer rather than a copy of it, so the colours it writes are the ones the popup draws, and it needs no WeatherKit entitlement.

Run `just colour-scales` to rewrite `Sources/MenuCalendar/WeatherColorScale.swift` from the current cache, or `--list` to print every scale it finds, including the air quality scales for twenty countries. The script only reads the cache; it fetches nothing and changes nothing outside this project.


## Trackpad gestures

Over the calendar, swipe horizontally with two fingers to pull the next or previous month into view. The page snaps into place when you commit the swipe.

Over the globe, drag or use two fingers to orbit the Earth, then release to let it coast. Pinch over the globe to zoom into the spot beneath the pointer. The popup temporarily takes app focus while the pointer is over the calendar or globe and returns it when you move away. A double-click zooms into that spot too. Globe zoom goes up to 7.2×. Hover over the city control to open the picker, then pause on a name for a closer look, or click it to focus immediately. Choose **Reset Globe** in the options menu to return to the default 3.1× view. Pinch together to pull back for the full Earth.

Supported Force Touch trackpads give a small tap when a month or city selection commits and when zoom snaps to its limits.

## Clock position

The app uses pointer coordinates and the menu bar’s bounds. It requires no Accessibility or Screen Recording permission. The default hover area is 145 points wide and ends 20 points from the right edge, matching the tested macOS 27 clock layout. If your clock format or menu bar layout changes, set the width and right inset in points, then relaunch the app.

```sh
defaults write local.menucalendar.app ClockHoverWidth -float 145
defaults write local.menucalendar.app ClockHoverRightInset -float 20
```

The build script signs the app locally. Set `CODE_SIGN_IDENTITY` when building if you have a signing identity you want to reuse.
