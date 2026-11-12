import Foundation

/// Keeps the Figma personal access token in a private file in Margin's
/// Application Support folder, readable only by you.
///
/// It used to live in the login keychain, but Margin is built locally and
/// signed ad hoc, so every update looks like a new app to the keychain and
/// macOS asked for your password again. The old keychain item is left alone
/// (reading it would ask once more); paste the token again in Settings if
/// you used one.
enum Keychain {
    private static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("figma-token")
    }

    static var figmaToken: String? {
        get {
            guard let data = try? Data(contentsOf: url),
                  let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try? Data(value.utf8).write(to: url, options: .atomic)
            // Owner read and write only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
