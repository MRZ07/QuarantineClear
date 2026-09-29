import Darwin
import Foundation

public enum XattrError: Error, Equatable, Sendable {
    case notFound(path: String, errno: Int32)
    case denied(path: String, errno: Int32)
    case failed(path: String, operation: String, errno: Int32)

    public var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }
}

/// Thin, stateless wrapper over the libc extended-attribute API.
///
/// The `/usr/bin/xattr` CLI is deliberately not used anywhere in this project. Measured
/// behaviour of the CLI makes it unfit for this job: it exits non-zero on an
/// already-clean file ("No such xattr"), it prints nothing on success, and it exits zero
/// even when a write silently fails. Reading the attribute directly makes absence a
/// first-class, expected outcome and yields an exact errno per file.
public enum Xattr {
    /// Ask the kernel to operate on a symlink itself rather than its target.
    /// Every call passes this, making "never traverse through a symlink" a kernel-enforced
    /// invariant instead of a convention the walker must remember.
    static let noFollow: Int32 = 0x0001

    private static let maxBufferRetries = 4

    static func classify(path: String, operation: String, code: Int32) -> XattrError {
        switch code {
        case ENOATTR: return .notFound(path: path, errno: code)
        case EACCES, EPERM: return .denied(path: path, errno: code)
        default: return .failed(path: path, operation: operation, errno: code)
        }
    }

    public static func value(atPath path: String, attribute: String) throws -> Data {
        try path.withCString { cPath in
            try attribute.withCString { cAttribute in
                let probed = getxattr(cPath, cAttribute, nil, 0, 0, noFollow)
                guard probed >= 0 else {
                    throw classify(path: path, operation: "read", code: errno)
                }
                let size = Int(probed)
                guard size > 0 else { return Data() }

                var buffer = [UInt8](repeating: 0, count: size)
                let written = buffer.withUnsafeMutableBytes { raw -> Int in
                    getxattr(cPath, cAttribute, raw.baseAddress, size, 0, noFollow)
                }
                guard written >= 0 else {
                    throw classify(path: path, operation: "read", code: errno)
                }
                return Data(buffer[0..<written])
            }
        }
    }

    public static func names(atPath path: String) throws -> [String] {
        try path.withCString { cPath in
            var names: [String] = []
            for _ in 0..<maxBufferRetries {
                let needed = listxattr(cPath, nil, 0, noFollow)
                guard needed >= 0 else {
                    throw classify(path: path, operation: "list", code: errno)
                }
                guard needed > 0 else { return [] }

                var buffer = [CChar](repeating: 0, count: Int(needed))
                let filled = buffer.withUnsafeMutableBufferPointer { raw -> Int in
                    listxattr(cPath, raw.baseAddress, raw.count, noFollow)
                }
                if filled < 0 && errno == ERANGE { continue }
                guard filled >= 0 else {
                    throw classify(path: path, operation: "list", code: errno)
                }

                names.removeAll(keepingCapacity: true)
                var start = 0
                for index in 0..<Int(filled) {
                    guard buffer[index] == 0 else { continue }
                    if index > start {
                        names.append(
                            String(decoding: buffer[start..<index].map { UInt8(bitPattern: $0) },
                                   as: UTF8.self))
                    }
                    start = index + 1
                }
                return names
            }
            throw XattrError.failed(path: path, operation: "list", errno: ERANGE)
        }
    }

    /// Throws `.notFound` when the attribute is absent. Callers must treat that as an
    /// expected outcome ("already clean"), never as a failure.
    public static func remove(attribute: String, atPath path: String) throws {
        let result = path.withCString { cPath in
            attribute.withCString { cAttribute in
                removexattr(cPath, cAttribute, noFollow)
            }
        }
        guard result == 0 else {
            throw classify(path: path, operation: "remove", code: errno)
        }
    }

    /// Writing exists so fixtures and future callers share one implementation. The product
    /// itself never sets the flag: this app only ever removes it.
    public static func set(attribute: String, value: Data, atPath path: String) throws {
        let result = path.withCString { cPath in
            attribute.withCString { cAttribute in
                value.withUnsafeBytes { raw -> Int32 in
                    setxattr(cPath, cAttribute, raw.baseAddress, raw.count, 0, noFollow)
                }
            }
        }
        guard result == 0 else {
            throw classify(path: path, operation: "write", code: errno)
        }
    }

    /// The only place `.notFound` is collapsed to a boolean, so no other caller can
    /// accidentally re-derive the same rule differently.
    public static func has(attribute: String, atPath path: String) -> Bool {
        (try? value(atPath: path, attribute: attribute)) != nil
    }
}
