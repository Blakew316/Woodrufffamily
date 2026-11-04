import Foundation

/// Which build of Woodruff Family this is, as Settings → General shows it ("Build 412 · e7d8293"). scripts/deploy.sh
/// stamps every build it makes: the build number (CFBundleVersion) is how many commits the branch had, so a newer build
/// always has a higher number, and WoodruffCommit is the commit it was built from. A build from Xcode or CI has
/// neither: it's "Build 1".
enum AppBuild {
    /// The full hash of the commit this was built from; nil when the build wasn't stamped with one (the key is empty,
    /// or still the unexpanded "$(WOODRUFF_COMMIT)").
    static let commit: String? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "WoodruffCommit") as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }()

    /// CFBundleVersion: the build number ("1" for a build that wasn't stamped).
    static let build: String = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? "1" : value
    }()

    /// The commit's first seven characters, as git shows it.
    static var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// "Build 412 · e7d8293", or "Build 1" without a commit.
    static let label: String = {
        guard let short = shortCommit else { return "Build \(build)" }
        return "Build \(build) · \(short)"
    }()
}
