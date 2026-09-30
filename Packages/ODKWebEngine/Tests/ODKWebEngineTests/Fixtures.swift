import Foundation

/// Loads XForm test fixtures from standalone `.xml` files under `Fixtures/` (real
/// XML with proper syntax highlighting and no Swift string-escaping) rather than
/// embedding them as giant multi-line string literals directly in test source.
enum Fixtures {
    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures") else {
            fatalError("Missing fixture file: Fixtures/\(name).xml")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Couldn't read fixture Fixtures/\(name).xml: \(error)")
        }
    }
}
