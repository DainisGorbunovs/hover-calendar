#!/usr/bin/env python3
"""Regenerate WeatherColorScale.swift from Apple Weather's cached overlay metadata.

Apple Weather downloads the colour scales for its map overlays and caches them
on this Mac, unencrypted, under the user's own container:

    ~/Library/Containers/com.apple.weather/Data/Library/Caches/MapOverlays/
        <locale>-metadata

Opening Weather.app once and showing the map writes that file. This script
reads it, parses the colour scales out of it, and rewrites the Swift source the
globe renderer uses. It only reads; nothing is fetched and nothing is modified
outside this project.

Record grammar (little-endian):
    string      : u64 length + UTF-8 bytes
    optional<T> : 0x00 (nil) | 0x01 + T
    double      : 8 bytes IEEE-754
    scale       : string id, string unit, string name,
                  optional<double> min, double max,
                  optional<u64> stopCount, stop[stopCount]
    stop        : optional<string> label, string "#RRGGBBAA", double value

Usage:
    tools/extract-weather-color-scales.py            # rewrite the Swift source
    tools/extract-weather-color-scales.py --list     # just show what was found
"""
from __future__ import annotations

import argparse
import pathlib
import re
import struct
import sys

CACHE = pathlib.Path.home() / 'Library/Containers/com.apple.weather/Data/Library' \
                              '/Caches/MapOverlays'
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / \
    'Sources/MenuCalendar/WeatherColorScale.swift'
COLOR = re.compile(r'#[0-9A-Fa-f]{8}')
COLOR_RECORD = re.compile(rb'\x09\x00{7}#[0-9A-Fa-f]{8}')


class Archive:
    def __init__(self, data: bytes):
        self.data = data

    def u64(self, off: int) -> int:
        return struct.unpack_from('<Q', self.data, off)[0]

    def f64(self, off: int) -> float:
        return struct.unpack_from('<d', self.data, off)[0]

    def string(self, off: int):
        if off < 0 or off + 8 > len(self.data):
            return None
        n = self.u64(off)
        if n > 256 or off + 8 + n > len(self.data):
            return None
        raw = self.data[off + 8:off + 8 + n]
        if not all(32 <= c < 127 for c in raw):
            return None
        return raw.decode('utf-8'), off + 8 + n

    def string_ending_at(self, end: int):
        for length in range(0, 64):
            got = self.string(end - 8 - length)
            if got and got[1] == end:
                return got[0], end - 8 - length
        return None

    def stop(self, off: int):
        if off < 0 or off >= len(self.data):
            return None
        if self.data[off] == 0:
            label, cur = None, off + 1
        elif self.data[off] == 1:
            got = self.string(off + 1)
            if not got:
                return None
            label, cur = got
        else:
            return None
        got = self.string(cur)
        if not got or not COLOR.fullmatch(got[0]):
            return None
        color, cur = got
        if cur + 8 > len(self.data):
            return None
        return {'label': label, 'color': color, 'value': round(self.f64(cur), 4)}, cur + 8

    def stop_runs(self):
        starts = set()
        for match in COLOR_RECORD.finditer(self.data):
            color_off = match.start()
            for start in [color_off - 1] + [color_off - 9 - n for n in range(1, 48)]:
                if start >= 0 and self.stop(start):
                    starts.add(start)
                    break

        runs, current, first, cursor = [], [], None, None
        for start in sorted(starts):
            got = self.stop(start)
            if not got:
                continue
            stop, end = got
            if cursor is not None and start != cursor and current:
                runs.append((first, current))
                current = []
            if not current:
                first = start
            current.append(stop)
            cursor = end
        if current:
            runs.append((first, current))
        return runs

    def scale(self, first_stop: int, stops: list) -> dict:
        header = {'id': None, 'unit': None, 'name': None, 'min': None, 'max': None,
                  'declared': None, 'offset': first_stop, 'stops': stops}
        cur = first_stop
        if cur - 9 >= 0 and self.data[cur - 9] == 1:
            header['declared'] = self.u64(cur - 8)
            cur -= 9
        if cur - 8 >= 0:
            header['max'] = round(self.f64(cur - 8), 4)
            cur -= 8
        if cur - 9 >= 0 and self.data[cur - 9] == 1:
            header['min'] = round(self.f64(cur - 8), 4)
            cur -= 9
        names = []
        for _ in range(3):
            got = self.string_ending_at(cur)
            if not got:
                break
            names.insert(0, got[0])
            cur = got[1]
        for key, value in zip(('id', 'unit', 'name'), names[-3:]):
            header[key] = value
        return header


def load_scales():
    candidates = sorted(CACHE.glob('*-metadata'))
    if not candidates:
        sys.exit(f'No cached overlay metadata under {CACHE}.\n'
                 'Open Weather.app and show the map once, then run this again.')
    path = candidates[0]
    archive = Archive(path.read_bytes())
    scales = [archive.scale(off, stops) for off, stops in archive.stop_runs()]
    return path, scales


def pick(scales):
    """Temperature in Celsius, plus the two precipitation scales."""
    temperature = next((s for s in scales if s['name'] == 'Temperature' and s['id'] == 'C'), None)
    labelled = [s for s in scales
                if {'Light', 'Heavy'} <= {t['label'] for t in s['stops'] if t['label']}]
    precipitation = next((s for s in labelled if (s['max'] or 0) > 100), None)
    radar = next((s for s in labelled if s is not precipitation), None)
    missing = [n for n, s in (('temperature', temperature), ('precipitation', precipitation),
                              ('radar', radar)) if s is None]
    if missing:
        sys.exit('Could not find these scales in the cache: ' + ', '.join(missing))
    return temperature, precipitation, radar


def swift_stops(scale, indent='        '):
    lines = []
    for stop in scale['stops']:
        color = stop['color'].lstrip('#')
        r, g, b, a = (int(color[i:i + 2], 16) for i in (0, 2, 4, 6))
        lines.append(f'{indent}Stop(value: {stop["value"]}, r: {r}, g: {g}, b: {b}, a: {a}),')
    return '\n'.join(lines)


TEMPLATE = '''import Foundation

/// Colour ramps for the globe's weather overlays.
///
/// The temperature and precipitation ramps are Apple Weather's own published
/// map-overlay scales, read from this Mac's cached overlay metadata at
/// `~/Library/Containers/com.apple.weather/Data/Library/Caches/MapOverlays/`.
/// Each stop pairs a physical value with an 8-bit RGBA colour, and Apple
/// interpolates linearly between neighbouring stops.
///
/// Apple builds its wind ramp in code rather than publishing it in that
/// metadata, so `wind` below is copied from WeatherMaps itself: thirteen stops
/// on the Beaufort thresholds, defined in m/s over 0–70 m/s. Spread over that
/// range they rebuild the colour map Weather uploads to the GPU byte for byte.
///
/// Regenerate with `tools/extract-weather-color-scales.py`.
enum WeatherColorScale {{
    struct Stop {{
        let value: Double
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }}

    /// Degrees Celsius. Apple's "C" temperature scale, {temp_count} stops over {temp_min}…{temp_max} °C.
    static let temperature: [Stop] = [
{temperature}
    ]

    /// Millimetres per hour. Apple's precipitation forecast scale, {precip_count} stops
    /// over {precip_min}…{precip_max} mm/h. The low stops are almost transparent so light
    /// rain reads as a tint rather than a wash of colour.
    static let precipitation: [Stop] = [
{precipitation}
    ]

    /// dBZ reflectivity. Apple's precipitation radar scale, {radar_count} stops over
    /// {radar_min}…{radar_max} dBZ. Kept for reference; the globe renders the forecast scale.
    static let precipitationRadar: [Stop] = [
{radar}
    ]

    /// Kilometres per hour. Apple's wind scale: Beaufort thresholds in m/s, times 3.6,
    /// flat from force 12 (117 km/h) to the top of Apple's 70 m/s range (252 km/h).
    static let wind: [Stop] = [
        Stop(value: 0.0, r: 0, g: 120, b: 189, a: 255),
        Stop(value: 1.08, r: 0, g: 120, b: 189, a: 255),
        Stop(value: 5.4, r: 0, g: 120, b: 189, a: 255),
        Stop(value: 12.24, r: 0, g: 124, b: 193, a: 255),
        Stop(value: 19.8, r: 0, g: 126, b: 195, a: 255),
        Stop(value: 28.8, r: 0, g: 128, b: 197, a: 255),
        Stop(value: 38.88, r: 0, g: 131, b: 200, a: 255),
        Stop(value: 50.04, r: 0, g: 137, b: 205, a: 255),
        Stop(value: 61.92, r: 0, g: 138, b: 206, a: 255),
        Stop(value: 74.88, r: 0, g: 140, b: 208, a: 255),
        Stop(value: 88.2, r: 0, g: 142, b: 210, a: 255),
        Stop(value: 102.6, r: 0, g: 149, b: 217, a: 255),
        Stop(value: 117.0, r: 0, g: 157, b: 224, a: 255),
        Stop(value: 252.0, r: 0, g: 157, b: 224, a: 255),
    ]

    /// Samples a ramp at `value`, interpolating between the two surrounding
    /// stops and clamping past either end.
    static func color(in stops: [Stop], at value: Double) -> (r: Double, g: Double, b: Double, a: Double) {{
        guard let first = stops.first, let last = stops.last else {{ return (0, 0, 0, 0) }}
        func channels(_ stop: Stop) -> (r: Double, g: Double, b: Double, a: Double) {{
            (Double(stop.r) / 255, Double(stop.g) / 255, Double(stop.b) / 255, Double(stop.a) / 255)
        }}
        if value <= first.value {{ return channels(first) }}
        if value >= last.value {{ return channels(last) }}

        for index in 1..<stops.count {{
            let upper = stops[index]
            guard value <= upper.value else {{ continue }}
            let lower = stops[index - 1]
            let span = upper.value - lower.value
            let progress = span > 0 ? (value - lower.value) / span : 0
            let start = channels(lower)
            let end = channels(upper)
            return (start.r + (end.r - start.r) * progress,
                    start.g + (end.g - start.g) * progress,
                    start.b + (end.b - start.b) * progress,
                    start.a + (end.a - start.a) * progress)
        }}
        return channels(last)
    }}
}}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--list', action='store_true',
                        help='show every scale found and exit without writing')
    args = parser.parse_args()

    path, scales = load_scales()
    print(f'Read {len(scales)} colour scales from {path}')

    if args.list:
        for scale in scales:
            labels = [t['label'] for t in scale['stops'] if t['label']]
            print(f"  id={scale['id']!r} unit={scale['unit']!r} name={scale['name']!r} "
                  f"range=({scale['min']}, {scale['max']}) stops={len(scale['stops'])} "
                  f"labels={labels[:4]}")
        return

    temperature, precipitation, radar = pick(scales)
    for scale in (temperature, precipitation, radar):
        if scale['declared'] not in (None, len(scale['stops'])):
            sys.exit(f"Stop count mismatch in {scale['name']!r}: declared "
                     f"{scale['declared']}, parsed {len(scale['stops'])}")

    OUTPUT.write_text(TEMPLATE.format(
        temperature=swift_stops(temperature),
        precipitation=swift_stops(precipitation),
        radar=swift_stops(radar),
        temp_count=len(temperature['stops']),
        temp_min=temperature['stops'][0]['value'],
        temp_max=temperature['stops'][-1]['value'],
        precip_count=len(precipitation['stops']),
        precip_min=precipitation['stops'][0]['value'],
        precip_max=precipitation['stops'][-1]['value'],
        radar_count=len(radar['stops']),
        radar_min=radar['stops'][0]['value'],
        radar_max=radar['stops'][-1]['value'],
    ))
    print(f'Wrote {OUTPUT}')
    print(f"  temperature   {len(temperature['stops'])} stops")
    print(f"  precipitation {len(precipitation['stops'])} stops")
    print(f"  radar         {len(radar['stops'])} stops")


if __name__ == '__main__':
    main()
