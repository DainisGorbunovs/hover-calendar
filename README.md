# Menu Calendar

Hover over the built-in macOS menu-bar date and time to see the month beneath it. The calendar stays open as you move into it, so you can browse other months with the arrows or return with **Today**. The grid highlights today and shades weekend columns. Week numbers, the first day of the week, and weekends follow your Mac’s calendar and regional settings.

Switch to **World Clock** in the popup for London, New York, Chicago, San Francisco, Riga, and Taipei. The clocks refresh each minute and show 24-hour local time and UTC offsets, with time-zone abbreviations where available. A city’s date appears when it differs from yours.

## Build and run

Use macOS 13 or later with Xcode or the Swift command-line tools.

With `just` installed, run `just build` to build the app or `just run` to build and launch it. You can also use the build script directly.

```sh
./scripts/build-app.sh
open ".build/Menu Calendar.app"
```

Hover over the built-in date and time. Clicking the clock still opens Notification Center. Click the calendar’s **…** button and choose **Quit Menu Calendar** to exit.

## Clock position

The app uses pointer coordinates and the menu bar’s bounds. It requires no Accessibility or Screen Recording permission. The default hover area is 145 points wide and ends 20 points from the right edge, matching the tested macOS 27 clock layout. If your clock format or menu bar layout changes, set the width and right inset in points, then relaunch the app.

```sh
defaults write local.menucalendar.app ClockHoverWidth -float 145
defaults write local.menucalendar.app ClockHoverRightInset -float 20
```

The build script signs the app locally. Set `CODE_SIGN_IDENTITY` when building if you have a signing identity you want to reuse.
