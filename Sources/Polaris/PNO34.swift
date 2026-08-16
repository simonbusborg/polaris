import Foundation

/// Make/model/variant decoded locally from Polestar's `pno34` product code.
///
/// Polestar's GraphQL schema lost `content{}` and `features` in April 2026
/// (see the note on `fetchCarInfo`), which took the variant name with it.
/// `pno34` survived because the studio-render query still needs it, so we
/// decode it here instead of asking the network for something it no longer has.
struct PNO34 {
    let make: String
    let model: String?
    let variant: String?

    /// The raw code, kept so the menu can surface it for an unknown car.
    let raw: String

    /// A "Model · Variant" line, or nil when we know neither.
    var subtitle: String? {
        let parts = [model, variant].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension PNO34 {
    /// Prefix → model, longest match wins.
    ///
    /// These are the CMA/SPA2 platform type codes, the same ones Volvo uses:
    /// Polestar 2 is 534 the way an XC40 is 536. Only add an entry here once
    /// it's been read off a real car's `pno34` — a wrong guess here is worse
    /// than showing nothing, because it renders as fact in the menu.
    static let modelsByPrefix: [String: String] = [
        "534": "Polestar 2",
        // Read off a 2026 car whose modelName the API reported as "Polestar 4".
        "814": "Polestar 4",
    ]

    /// Full-prefix → variant, longest match wins.
    ///
    /// Deliberately empty. The variant (Single/Dual Motor, Standard/Long Range,
    /// Performance Pack) lives somewhere in the trailing characters, but the
    /// field offsets aren't published and guessing them would put an invented
    /// drivetrain in front of the user. Populate from known cars: take the
    /// `pno34` shown in the menu for a car whose variant you can confirm, and
    /// add the shortest prefix that identifies it.
    static let variantsByPrefix: [String: String] = [:]

    /// Decodes as much as the tables allow. Returns nil only for a blank code.
    ///
    /// `make` is unconditional: every car reachable through this API is a
    /// Polestar, so the field is never the unknown part.
    static func decode(_ raw: String?) -> PNO34? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return nil }

        return PNO34(make: "Polestar",
                     model: longestMatch(in: modelsByPrefix, for: code),
                     variant: longestMatch(in: variantsByPrefix, for: code),
                     raw: code)
    }

    private static func longestMatch(in table: [String: String], for code: String) -> String? {
        table
            .filter { code.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
