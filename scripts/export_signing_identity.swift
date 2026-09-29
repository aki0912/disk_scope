import Foundation
import Security
import CryptoKit

// Export only the explicitly selected identity; the password arrives on stdin.
func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
guard CommandLine.arguments.count == 3, let password = readLine(), !password.isEmpty else {
    fail("Expected certificate fingerprint, output file, and password on stdin")
}
let fingerprint = CommandLine.arguments[1].uppercased()
var result: CFTypeRef?
let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                           kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
    fail("Could not access signing identities (\(status))")
}
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
    let data = SecCertificateCopyData(certificate) as Data
    let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    guard digest == fingerprint else { continue }
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passRetained(password as CFString)
    defer { parameters.passphrase?.release() }
    var exported: CFData?
    let exportStatus = SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
    guard exportStatus == errSecSuccess, let exported else { fail("Identity export failed (\(exportStatus))") }
    do {
        try (exported as Data).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    } catch { fail("Could not write encrypted certificate") }
    exit(0)
}
fail("Selected certificate was not found")
