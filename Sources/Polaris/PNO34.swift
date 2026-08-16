import Foundation

/// The variant decoded locally from Polestar's `pno34` product code.
///
/// Polestar's GraphQL schema lost `content{}` and `features` in April 2026
/// (see the note on `fetchCarInfo`), which took the variant name with it.
/// `pno34` survived because the studio-render query still needs it, so we
/// decode it here instead of asking the network for something it no longer has.
///
/// Make and model deliberately aren't decoded: the menu's identity line
/// already reads "Polestar 4 · 2026" straight from the API, so the only thing
/// left worth naming is the drivetrain variant.
struct PNO34 {
    let variant: String?

    /// The raw code, kept so `debug_pno34` can surface it for an unknown car.
    let raw: String
}

extension PNO34 {
    /// Full-prefix → variant, longest match wins.
    ///
    /// Deliberately empty. The variant (Single/Dual Motor, Standard/Long Range,
    /// Performance Pack) lives somewhere in the trailing characters, but the
    /// field offsets aren't published and guessing them would put an invented
    /// drivetrain in front of the user. Populate from known cars: turn on
    /// `debug_pno34`, take the code shown for a car whose variant you can
    /// confirm, and add the shortest prefix that identifies it.
    ///
    /// The first three characters are the platform type code — 534 is a
    /// Polestar 2, 814 a Polestar 4, both read off real cars — so a prefix
    /// shorter than that would match across models.
    static let variantsByPrefix: [String: String] = [:]

    /// Decodes as much as the table allows. Returns nil only for a blank code.
    static func decode(_ raw: String?) -> PNO34? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return nil }

        return PNO34(variant: longestMatch(in: variantsByPrefix, for: code), raw: code)
    }

    private static func longestMatch(in table: [String: String], for code: String) -> String? {
        table
            .filter { code.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
