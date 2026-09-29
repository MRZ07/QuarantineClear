import Darwin
import Foundation
import Security

/// How a bundle is signed, and what that means for Gatekeeper.
///
/// The distinction matters because the quarantine flag alone does not predict whether an
/// app will open. macOS enforces Gatekeeper on *first* launch only: once a user has
/// approved an app, it opens from then on whether or not the flag is still present. So
/// "flagged" and "will not open" are not the same question, and this type exists so the UI
/// can stop implying they are.
///
public enum SignatureInspector {
    /// Cheap: reads signing metadata only, never re-hashes the bundle's resources.
    ///
    /// Costs about 0.15s for every flagged app in /Applications, versus 10s for a full
    /// validity check. Note what this does *not* tell you: a Developer ID app whose
    /// notarisation is missing still passes `SecStaticCodeCheckValidity`, because
    /// notarisation is a Gatekeeper policy decision rather than a code-signing one.
    /// Nothing cheap in-process answers "will Gatekeeper refuse this" — see
    /// `GatekeeperAssessor` for the honest, on-demand answer.
    public static func kind(at url: URL) -> SignatureStatus {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let staticCode = code else { return .unsigned }

        // kSecCSSigningInformation is mandatory here. Without it the Signing keys are
        // simply absent from the dictionary, and every app looks ad-hoc signed.
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                           SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return .unsigned }

        // Code that shipped with the OS is identified by a platform identifier, and is
        // signed by Apple rather than a Developer ID. Equally trusted.
        if dictionary[kSecCodeInfoPlatformIdentifier as String] != nil { return .trusted }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
           team == "Software Signing" {
            return .trusted
        }
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [Any] {
            var authorities: [String] = []
            for case let certificate as SecCertificate in certificates {
                if let subject = SecCertificateCopySubjectSummary(certificate) as String? {
                    authorities.append(subject)
                }
            }
            if authorities.contains(where: { $0.contains("Developer ID") }) { return .trusted }
            if authorities.contains(where: { $0.contains("Apple Code Signing")
                || $0.contains("Apple Root CA") }) { return .trusted }
            if !authorities.isEmpty {
                return .otherCertificate(authorities.joined(separator: ", "))
            }
        }
        if dictionary[kSecCodeInfoIdentifier as String] != nil { return .adHoc }
        return .unsigned
    }

    /// Checks the seal: does the code on disk match what was signed?
    ///
    /// This is the cheap half of the only combination that predicts Gatekeeper. Measured
    /// over the flagged apps in /Applications, seal failures agree with `spctl` rejections
    /// exactly (Bionic.app and LM Studio.app, OSStatus -67054, "a sealed resource is
    /// missing or invalid"), while `SecStaticCodeCheckValidity` accepts the other 37 —
    /// which is precisely where the old signature-only predicate went wrong.
    ///
    /// It is still too slow for a scan — about 5s for 39 bundles even in parallel — so it
    /// runs as a background pass over flagged rows only, never over a whole folder.
    public static func verify(at url: URL) -> Verification {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let staticCode = code else { return .blocked(reason: "no code signature found") }
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: 0), nil)
        switch status {
        case errSecSuccess:
            return .opensFine
        case errSecCSUnsigned:
            return .blocked(reason: "unsigned")
        default:
            return .blocked(reason: sealReason(for: status))
        }
    }

    private static func sealReason(for status: OSStatus) -> String {
        // -67054 is what a bundle with a missing or invalid sealed resource reports;
        // spell it out, because a bare number in the UI explains nothing.
        if status == -67054 { return "a sealed resource is missing or invalid" }
        return "seal check failed (OSStatus \(status))"
    }

    /// Expensive. Used only for a single bundle the user has opened.
    public static func validity(at url: URL) -> SignatureStatus {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let staticCode = code else { return .unsigned }
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: 0), nil)
        if status == errSecSuccess { return .trusted }
        if status == errSecCSUnsigned { return .unsigned }
        return .otherCertificate("OSStatus \(status)")
    }
}
