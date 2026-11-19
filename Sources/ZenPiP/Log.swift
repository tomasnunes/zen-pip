import Foundation

/// Writes a timestamped line to standard error, which the login item sends to ~/Library/Logs/ZenPiP.log.
/// Only start-up and problems are logged, unless the `debug` setting is on.
enum Log {
    static func write(_ message: @autoclosure () -> String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime,
                                                                .withSpaceBetweenDateAndTime])
        FileHandle.standardError.write("\(stamp) \(message())\n".data(using: .utf8)!)
    }
}
