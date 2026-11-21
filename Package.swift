// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MenuCalendar",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "MenuCalendar", resources: [.copy("EarthTextures"), .copy("UKBankHolidays.json")])]
)
