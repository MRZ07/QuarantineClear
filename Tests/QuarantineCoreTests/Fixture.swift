import Foundation
import XCTest

@testable import QuarantineCore

/// Disposable bundle trees under the system temp directory. No test may touch a real
/// `/Applications` entry, so every path a test asserts on comes from here.
final class Fixture {
    let root: URL
    private let fileManager = FileManager.default

    init(name: String = UUID().uuidString) {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qc-tests-\(name)")
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? fileManager.removeItem(at: root) }

    private func path(_ components: String...) -> String {
        components.joined(separator: "/")
    }

    @discardableResult
    func app(named name: String, files: [String] = ["Contents/MacOS/Binary", "Contents/Info.plist"],
             quarantine: Bool = true, extraXattrs: [String: String] = [:]) throws -> String {
        let appPath = path("apps", "\(name).app")
        let appURL = URL(fileURLWithPath: root.path).appendingPathComponent(appPath)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        for file in files {
            let fileURL = appURL.appendingPathComponent(file)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: fileURL)
            if quarantine {
                try Xattr.set(attribute: QuarantineAttribute.name, value: Data(Self.samplePayload.utf8),
                              atPath: fileURL.path)
            }
        }
        if quarantine {
            try Xattr.set(attribute: QuarantineAttribute.name, value: Data(Self.samplePayload.utf8),
                          atPath: appURL.path)
        }
        for (attribute, value) in extraXattrs {
            try Xattr.set(attribute: attribute, value: Data(value.utf8), atPath: appURL.path)
        }
        return appURL.path
    }

    /// A helper bundle living inside another app, as Chromium and Electron apps ship.
    @discardableResult
    func nestedApp(named name: String, in parent: String) throws -> String {
        let appPath = path("apps", "\(parent).app", "Contents", "Frameworks", "\(name).app")
        let appURL = URL(fileURLWithPath: root.path).appendingPathComponent(appPath)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        let binary = appURL.appendingPathComponent("Contents/MacOS/Binary")
        try fileManager.createDirectory(at: binary.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: binary)
        try Xattr.set(attribute: QuarantineAttribute.name, value: Data(Self.samplePayload.utf8),
                      atPath: appURL.path)
        return appURL.path
    }

    @discardableResult
    func symlink(_ name: String, at directory: String, to target: String) throws -> String {
        let linkURL = URL(fileURLWithPath: root.path)
            .appendingPathComponent(path(directory, name))
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkURL,
                                           withDestinationURL: URL(fileURLWithPath: root.path)
                                               .appendingPathComponent(target))
        return linkURL.path
    }

    @discardableResult
    func plainFile(_ name: String, at directory: String, quarantined: Bool = true) throws -> String {
        let fileURL = URL(fileURLWithPath: root.path).appendingPathComponent(path(directory, name))
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("plain".utf8).write(to: fileURL)
        if quarantined {
            try Xattr.set(attribute: QuarantineAttribute.name, value: Data(Self.samplePayload.utf8),
                          atPath: fileURL.path)
        }
        return fileURL.path
    }

    func emptyDirectory(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: root.path).appendingPathComponent(name)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func url(_ path: String) -> URL { URL(fileURLWithPath: root.path).appendingPathComponent(path) }

    static let samplePayload = "0083;68f5a0c0;Safari;7C7C;https://example.com/App.dmg"
}
