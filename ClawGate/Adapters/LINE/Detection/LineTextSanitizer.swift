import Foundation

enum LineTextSanitizer {
    private static let standaloneNoiseTokens: Set<String> = [
        "既読", "未読", "もっと見る", "続きを読む", "入力中", "オンライン",
    ]

    static func sanitize(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var kept: [String] = []
        for line in lines {
            guard !isStandaloneUIArtifact(line) else { continue }
            kept.append(line)
        }
        // Drop obvious OCR crumbs only when there is enough real content.
        if kept.count >= 2 {
            kept = kept.filter { !isShortAsciiCrumb($0) }
        }
        return kept.joined(separator: "\n")
    }

    static func normalizeForEcho(_ text: String) -> String {
        let lowered = text.lowercased()
        let folded = lowered.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        return folded.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet(charactersIn: "\u{3040}"..."\u{30ff}").contains(scalar) // ひらがな/カタカナ
                || CharacterSet(charactersIn: "\u{4e00}"..."\u{9faf}").contains(scalar) // CJK
        }.map(String.init).joined()
    }

    static func textLikelyContainsSentText(candidate: String, sentText: String) -> Bool {
        let cleanCandidate = normalizeForEcho(candidate)
        let cleanSent = normalizeForEcho(sentText)
        guard cleanSent.count >= 6 else {
            return false
        }
        if cleanCandidate == cleanSent {
            return true
        }

        if cleanCandidate.contains(cleanSent) {
            let dominance = Double(cleanSent.count) / Double(max(cleanCandidate.count, 1))
            // Avoid false echo when OCR text is a long mixed block and only one line matches.
            return dominance >= 0.70
        }

        if cleanSent.contains(cleanCandidate) {
            let coverage = Double(cleanCandidate.count) / Double(max(cleanSent.count, 1))
            return coverage >= 0.85
        }

        return false
    }

    static func isStandaloneUIArtifact(_ line: String) -> Bool {
        if standaloneNoiseTokens.contains(line) {
            return true
        }
        if isInputPlaceholderLine(line) {
            return true
        }
        if line == "ここから未読メッセージ" {
            return true
        }
        if isTimeOnlyLine(line) {
            return true
        }
        return isMostlySymbols(line)
    }

    private static func isTimeOnlyLine(_ line: String) -> Bool {
        let patterns = [
            #"^\d{1,2}:\d{2}$"#,
            #"^\d{1,2}:\d{2}:\d{2}$"#,
            #"^(午前|午後)\s*\d{1,2}:\d{2}$"#,
            #"^[=~\-–—\s]*(午前|午後|前|後)\s*\d{1,2}:\d{2}$"#,
        ]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isShortAsciiCrumb(_ line: String) -> Bool {
        line.range(of: #"^[A-Za-z]$"#, options: .regularExpression) != nil
            || line.range(of: #"^[=~\-–—•·\s]+$"#, options: .regularExpression) != nil
    }

    private static func isInputPlaceholderLine(_ line: String) -> Bool {
        let compact = line
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        let patterns = [
            #"^メ[ッツ]セージを入力$"#,
            #"^messageinput$"#,
            #"^メ[ッツ]セージ入力$"#,
        ]
        return patterns.contains { compact.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func isMostlySymbols(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        let symbolLike = line.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) == false
                && CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                && CharacterSet(charactersIn: "\u{3040}"..."\u{30ff}").contains(scalar) == false
                && CharacterSet(charactersIn: "\u{4e00}"..."\u{9faf}").contains(scalar) == false
        }.count
        return symbolLike >= line.count
    }
}
