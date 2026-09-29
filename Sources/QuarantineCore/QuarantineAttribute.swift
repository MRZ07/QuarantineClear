import Foundation

/// The single authority for the quarantine attribute's name and payload format.
/// No other file in this project may contain the literal attribute name.
public enum QuarantineAttribute {
    public static let name = "com.apple.quarantine"
}

public enum QuarantineKind: String, Sendable, Equatable {
    case none
    case url
    case filePath

    /// Derived from the origin string, never from the flags field. Real payloads carry a
    /// hex bitmask in field 4 (`7C7C` is the common value), so mapping that field onto a
    /// kind would report every downloaded app as `.appStore`.
    static func from(identifier: String?) -> QuarantineKind {
        guard let identifier, !identifier.isEmpty else { return .none }
        let lowered = identifier.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return .url }
        return .filePath
    }
}

public struct QuarantineOrigin: Equatable, Sendable {
    public let flags: Int
    public let timestamp: Date?
    public let agent: String?
    public let kind: QuarantineKind
    public let identifier: String?
    /// Retained verbatim so a payload this parser does not understand can still be shown
    /// to the user honestly instead of being displayed as a confidently wrong value.
    public let raw: String

    public init(flags: Int, timestamp: Date?, agent: String?, kind: QuarantineKind,
                identifier: String?, raw: String) {
        self.flags = flags
        self.timestamp = timestamp
        self.agent = agent
        self.kind = kind
        self.identifier = identifier
        self.raw = raw
    }
}

/// Tolerant parser for `flags;hexUnixTimestamp;agent;typeHex;identifier`.
///
/// Producers omit trailing fields, so every field is optional and a field that does not
/// parse becomes `nil`. The parser never fabricates a URL: a caller that cannot account
/// for the shape is better served by the raw string than by an invented origin.
public enum QuarantinePayloadParser {
    private static let fieldCount = 5

    public static func parse(_ data: Data) -> QuarantineOrigin? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return nil }

        let flags = Int(fields[0], radix: 16) ?? 0
        let timestamp = Date(timeIntervalSince1970: TimeInterval(hexSeconds(fields[1])))
        let agent = fields.count > 2 ? nonEmpty(fields[2]) : nil
        let identifier = fields.count > 4 ? nonEmpty(fields[4]) : nil
        let kind = QuarantineKind.from(identifier: identifier)

        return QuarantineOrigin(flags: flags, timestamp: timestamp, agent: agent,
                                kind: kind, identifier: identifier, raw: text)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func hexSeconds(_ field: String) -> Double {
        guard let value = UInt64(field, radix: 16) else { return 0 }
        return Double(value)
    }
}

extension QuarantineAttribute {
    /// The equivalent command a user can run by hand, quoted because bundle paths routinely
    /// contain spaces. One authority for the text: the CLI prints it, the app copies it, and
    /// they must not be able to drift apart.
    public static func manualCommand(forPath path: String) -> String {
        "xattr -rd \(name) '\(path)'"
    }
}
