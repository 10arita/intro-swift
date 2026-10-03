import Foundation

enum RoomCode {
    static let length = 6

    static func normalizedInput(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.uppercased()
            .unicodeScalars.filter { (65...90).contains($0.value) }.map(Character.init).prefix(length))
    }

    static func isValid(_ code: String) -> Bool {
        code.count == length && code.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
    }

    /// Accept a bare code or a code in an invitation, without truncating longer tokens.
    static func pastedCode(in text: String) -> String? {
        let value = text.precomposedStringWithCompatibilityMapping.uppercased()
        let compact = value.filter { !$0.isWhitespace }
        if isValid(compact) { return compact }
        let pattern = #"(?:ルーム(?:コード|ID)|参加コード|ROOM\s*(?:CODE|ID))\s*[:：]?\s*([A-Z]{6})(?![A-Z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}
