/// POSIX shell quoting: each word in single quotes, so nothing in it is interpreted.
public enum Shell {
    public static func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func line(_ argv: [String]) -> String { argv.map(quote).joined(separator: " ") }
}
