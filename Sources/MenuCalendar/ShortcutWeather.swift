import Foundation

/// Apple Weather's forecast across a whole grid, by way of a shortcut.
///
/// Shortcuts' Get Weather Forecast action runs under Shortcuts' own WeatherKit
/// entitlement, and Apple built Shortcuts to be scripted, so a shortcut the
/// user has added can sample the region's grid for a build that has no
/// entitlement of its own. The "Menu Calendar Weather" shortcut, written by
/// tools/make-weather-shortcut.py, takes one Apple Maps link per grid point and
/// answers with every point's hourly forecast in °C, mm and km/h.
enum ShortcutWeather {
    static let name = "Menu Calendar Weather"
    /// The first line of every answer. A shortcut that does not open with it
    /// predates the format this build reads and has to be replaced.
    static let header = "menu-calendar-weather 2"
    private static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    private static let directoryPrefix = "MenuCalendarWeather-"
    /// A fresh grid takes several seconds; this is the point past which
    /// something has gone wrong rather than merely being slow.
    private static let timeout: TimeInterval = 120

    enum Failure: Error, Equatable {
        case notInstalled
        case outdated
        case timedOut
        case failed
        case unreadable
    }

    /// Names a failure without repeating anything Shortcuts said, which can
    /// mention the places it was asked about.
    static func describe(_ error: Error) -> String {
        switch error {
        case Failure.notInstalled: "not installed"
        case Failure.outdated: "outdated shortcut"
        case Failure.timedOut: "timed out"
        case Failure.failed: "run failed"
        case Failure.unreadable: "unreadable answer"
        default: String(describing: type(of: error))
        }
    }

    /// Every grid point's hourly forecast, row by row from the region's
    /// north-west corner, in the order `WeatherRegion.coordinate` gives.
    static func forecasts(for region: WeatherRegion) async throws -> [[Date: WeatherSample]] {
        let side = WeatherRegion.side
        let points = (0..<side).flatMap { row in
            (0..<side).map { column in region.coordinate(row: row, column: column) }
        }
        let output = try await run(input: links(for: points))
        return try parse(output, points: points.count)
    }

    /// One Apple Maps link per point. Shortcuts will not turn plain text into a
    /// location, but it turns a Maps link into a placemark at exactly the
    /// link's coordinate.
    static func links(for points: [(latitude: Double, longitude: Double)]) -> String {
        points.map { String(format: "https://maps.apple.com/?ll=%.4f,%.4f", $0.latitude, $0.longitude) }
            .joined(separator: "\n")
    }

    /// Reads the header, then lines of `point|ISO date|°C|mm|km/h|bearing`.
    /// Lines that do not parse, or whose values fall outside what weather can
    /// be, are dropped rather than guessed at; `AppleWeatherService` then keeps
    /// only the hours every point reported.
    static func parse(_ text: String, points: Int) throws -> [[Date: WeatherSample]] {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let first = lines.next(),
              first.trimmingCharacters(in: .whitespaces) == header
        else { throw Failure.outdated }

        var grid = Array(repeating: [Date: WeatherSample](), count: points)
        let dates = ISO8601DateFormatter()
        var accepted = 0

        while let line = lines.next() {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6,
                  let index = number(fields[0]), index == index.rounded(),
                  (1...Double(points)).contains(index),
                  let date = dates.date(from: fields[1]),
                  let temperature = number(fields[2]), (-90...70).contains(temperature),
                  let precipitation = number(fields[3]), (0...500).contains(precipitation),
                  let speed = number(fields[4]), (0...500).contains(speed),
                  let bearing = number(fields[5]), (0...360).contains(bearing)
            else { continue }

            let radians = bearing * .pi / 180
            grid[Int(index) - 1][date] = WeatherSample(temperature: temperature,
                                                       precipitation: precipitation,
                                                       east: -sin(radians) * speed,
                                                       north: -cos(radians) * speed)
            accepted += 1
        }
        guard accepted > 0 else { throw Failure.unreadable }
        return grid
    }

    private static let localNumbers: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()
    private static let localNumbersLock = NSLock()

    /// Shortcuts writes numbers the way the Mac's region does, which can mean a
    /// decimal comma, a Unicode minus, direction marks around the sign, or a
    /// script's own digits. Plain forms are read directly; anything else goes
    /// through a formatter for the same region.
    static func number(_ field: String) -> Double? {
        let marks: Set<Character> = ["\u{200E}", "\u{200F}", "\u{061C}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        var plain = String(field.filter { !marks.contains($0) })
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !plain.isEmpty else { return nil }
        plain = plain.replacingOccurrences(of: ",", with: ".")
        if let value = Double(plain) { return value.isFinite ? value : nil }

        localNumbersLock.lock()
        defer { localNumbersLock.unlock() }
        return localNumbers.number(from: field)?.doubleValue
            ?? localNumbers.number(from: field.filter { !marks.contains($0) })?.doubleValue
    }

    // MARK: Running the shortcut

    private final class Run {
        let process: Process
        let directory: URL
        var superseded = false
        init(process: Process, directory: URL) { self.process = process; self.directory = directory }
    }

    private static let runningLock = NSLock()
    nonisolated(unsafe) private static var running: Run?

    /// Stops a run in progress and removes its files, for when the app quits.
    static func terminateRunning() {
        runningLock.lock()
        defer { runningLock.unlock() }
        guard let run = running else { return }
        if run.process.isRunning { run.process.terminate() }
        try? FileManager.default.removeItem(at: run.directory)
        running = nil
    }

    /// Stops a run whose answer is no longer wanted. It ends with a
    /// CancellationError rather than counting as the shortcut failing.
    static func supersedeRunning() {
        runningLock.lock()
        defer { runningLock.unlock() }
        guard let run = running, run.process.isRunning else { return }
        run.superseded = true
        run.process.terminate()
    }

    /// Removes files left by a run the app did not live to clean up after.
    static func removeLeftovers() {
        let temporary = FileManager.default.temporaryDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for entry in entries where entry.hasPrefix(directoryPrefix) {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(entry))
        }
    }

    private static func track(_ process: Process, in directory: URL) -> Run {
        runningLock.lock()
        defer { runningLock.unlock() }
        let run = Run(process: process, directory: directory)
        running = run
        return run
    }

    /// Forgets the run, and says whether it was stopped for a newer one.
    private static func untrack(_ run: Run) -> Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        if running === run { running = nil }
        return run.superseded
    }

    private static func run(input: String) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("points.txt")
        let outputURL = directory.appendingPathComponent("forecast.txt")
        try input.write(to: inputURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", name, "--input-path", inputURL.path, "--output-path", outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        let tracked = track(process, in: directory)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                _ = untrack(tracked)
                continuation.resume(throwing: error)
            }
        }

        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if untrack(tracked) { throw CancellationError() }
        if process.terminationReason == .uncaughtSignal { throw Failure.timedOut }
        guard status == 0 else {
            throw message.localizedCaseInsensitiveContains("find shortcut") ? Failure.notInstalled : Failure.failed
        }
        guard let output = try? String(contentsOf: outputURL, encoding: .utf8), !output.isEmpty else {
            throw Failure.failed
        }
        return output
    }
}
