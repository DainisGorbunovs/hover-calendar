# Menu Calendar

Hover over the built-in macOS menu-bar date and time to see the calendar, daylight globe, and six world clocks together. The calendar stays open as you move into it, so you can browse with the arrows or return with **Today**. Click the month heading to jump directly to another month or type a year. Click a date to keep its details in the footer. The grid highlights today, shades weekend columns, and marks public holidays with a teal dot. Hover over a date for a raised highlight and its date or holiday name. The calendar shows the next holiday in the month when available. Week numbers, the first day of the week, and weekends follow your Mac’s calendar and regional settings.

The world-clock strip shows London, New York, Chicago, San Francisco, Riga, and Taipei. The clocks run from earliest to latest local date and time and refresh each minute and show 24-hour local time and UTC offsets, with time-zone abbreviations where available. A city’s date appears when it differs from yours. Pause over a city in the strip to fly to it. Long flights pull back for the turn and then zoom in on arrival. The daylight strip shows local sunrise, sunset, and the city’s position in its day. Clicking a city focuses it immediately.

The globe updates its solar lighting every minute. It renders terrain, ocean reflections, cloud shadows, twilight, and city lights. The cloud layer uses a [NASA satellite composite](https://science.nasa.gov/earth/earth-observatory/the-blue-marble-true-color-global-imagery-at-1km-resolution/) with lighting calculated for the current time. It works offline with satellite composites from [NASA Blue Marble Next Generation](https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-topography/) and [NASA Black Marble](https://science.nasa.gov/earth/earth-observatory/earth-at-night/maps/). The Sun’s position is calculated using [U.S. Naval Observatory solar coordinates](https://aa.usno.navy.mil/faq/sun_approx) and [sidereal time](https://aa.usno.navy.mil/faq/GAST).

Imagery credits go to NASA Earth Observatory and Reto Stöckli (Blue Marble) and to Joshua Stevens using Suomi NPP VIIRS data from Miguel Román, NASA GSFC (Black Marble).

Choose **US**, **E&W**, **SCO**, or **NI** in the calendar footer to change which holidays you see. The default follows the Mac’s region for the United States and United Kingdom. The U.S. calendar includes nationwide federal holidays and their observed weekdays. The UK schedules include officially published substitute days and currently cover 2019–2028. [U.S. Office of Personnel Management](https://www.opm.gov/policy-data-oversight/pay-leave/federal-holidays/) · [GOV.UK bank holidays](https://www.gov.uk/bank-holidays)

## Build and run

Use macOS 13 or later with Xcode or the Swift command-line tools.

With `just` installed, run `just build` to build the app or `just run` to build and launch it. You can also use the build script directly.

```sh
./scripts/build-app.sh
open ".build/Menu Calendar.app"
```

Hover over the built-in date and time or the space directly above it. Clicking the clock still opens Notification Center. Click **…** over the globe and choose **Quit Menu Calendar** to exit.

## Trackpad gestures

Over the calendar, swipe horizontally with two fingers to pull the next or previous month into view. The page snaps into place when you commit the swipe.

Over the globe, drag or use two fingers to orbit the Earth, then release to let it coast. Pinch over the globe to zoom into the spot beneath the pointer. The globe temporarily takes app focus for trackpad input and returns it when you move away. A double-click zooms into that spot too. The zoom buttons work at the center of the globe and the scale readout shows the current level, up to 4.8×. Hover over the city control to open the picker, then pause on a name for a closer look, or click it to focus immediately. The reset button returns to the default 1.44× view. Use zoom out for the full Earth.

Supported Force Touch trackpads give a small tap when a month or city selection commits and when zoom snaps to its limits.

## Clock position

The app uses pointer coordinates and the menu bar’s bounds. It requires no Accessibility or Screen Recording permission. The default hover area is 145 points wide and ends 20 points from the right edge, matching the tested macOS 27 clock layout. If your clock format or menu bar layout changes, set the width and right inset in points, then relaunch the app.

```sh
defaults write local.menucalendar.app ClockHoverWidth -float 145
defaults write local.menucalendar.app ClockHoverRightInset -float 20
```

The build script signs the app locally. Set `CODE_SIGN_IDENTITY` when building if you have a signing identity you want to reuse.
