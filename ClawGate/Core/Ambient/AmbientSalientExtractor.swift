import Foundation
import CryptoKit
import NaturalLanguage

/// Rule-based L2 salient-event extraction (contract: ambient-context.md,
/// "L2 Salient Event Schema"). Phase 2 first slice: conservative,
/// high-precision rules for `todo` / `appointment` / `commitment` only —
/// missing an event is acceptable, injecting noise into Chi's context is not.
///
/// Privacy: subjects are content nouns only; words tagged as personal/place/
/// organization names are excluded (same default-redact posture as the L1
/// summary). A segment that yields no safe nouns yields no event.
enum AmbientSalientExtractor {
    struct Draft: Equatable {
        let eventType: String           // todo | appointment | commitment
        let normalizedSubject: String
        let normalizedDateBucket: String?
        let dedupKey: String
        let summary: String
        let confidence: Double
    }

    // MARK: - Rules

    private static let todoMarkers = [
        "todo", "やらないと", "やらなきゃ", "しないと", "しなきゃ", "忘れずに", "やっておかないと",
        "買っておく", "need to ", "have to ", "don't forget", "must ",
    ]
    private static let appointmentMarkers = [
        "会う", "打ち合わせ", "ミーティング", "会議", "予定", "アポ",
        "meeting", "appointment", "meet ",
    ]
    private static let belongingMarkers = [
        "持ってく", "持っていく", "持って行く", "持ち物", "bring ",
    ]
    private static let commitmentMarkers = [
        "約束", "しておきます", "しておくね", "やっておきます", "送っておきます",
        "i'll ", "i will ", "promise",
    ]

    /// Precision guards: a matching segment is NOT extracted at all.
    /// False negatives are acceptable; injecting noise into Chi is not.
    private static let retrospectiveMarkers = [
        // Past events are recall material, not upcoming salient events.
        "昨日", "先週", "先月", "yesterday", "last week", "last month",
    ]
    private static let mediaMarkers = [
        // TV / video boilerplate (also whisper's favourite hallucination shapes).
        "ご視聴", "チャンネル登録", "お送りしました", "thanks for watching", "subscribe",
    ]
    private static let hearsayMarkers = [
        // Third-party plans relayed second-hand are not the 御大's commitments.
        "らしい", "そうだ", "って言ってた", "みたいだよ", "apparently", "i heard",
    ]

    /// Extract drafts from one window's kept segment texts.
    static func extract(from segmentTexts: [String],
                        now: Date = Date(),
                        calendar: Calendar = .current) -> [Draft] {
        var drafts: [Draft] = []
        var seenKeys = Set<String>()
        for text in segmentTexts {
            guard let draft = extractOne(from: text, now: now, calendar: calendar) else { continue }
            if seenKeys.insert(draft.dedupKey).inserted {
                drafts.append(draft)
            }
        }
        return drafts
    }

    static func extractOne(from text: String,
                           now: Date = Date(),
                           calendar: Calendar = .current) -> Draft? {
        let lowered = text.lowercased()

        // Precision guards first: retrospective talk, media boilerplate, and
        // hearsay about third parties are never extracted.
        let guarded = retrospectiveMarkers + mediaMarkers + hearsayMarkers
        if guarded.contains(where: { lowered.contains($0) }) { return nil }

        let bucket = dateBucket(in: lowered, now: now, calendar: calendar)

        let eventType: String
        let confidence: Double
        if appointmentMarkers.contains(where: { lowered.contains($0) }), bucket != nil {
            // Appointment requires an explicit date reference — strongest signal.
            eventType = "appointment"; confidence = 0.7
        } else if belongingMarkers.contains(where: { lowered.contains($0) }) {
            eventType = "belonging"; confidence = 0.6
        } else if todoMarkers.contains(where: { lowered.contains($0) }) {
            eventType = "todo"; confidence = 0.6
        } else if commitmentMarkers.contains(where: { lowered.contains($0) }) {
            eventType = "commitment"; confidence = 0.55
        } else {
            // proper_noun is deliberately NOT extracted in this slice: without
            // JP POS/name tagging there is no precision-safe rule for it, and
            // false negatives are the accepted trade (contract precision rule).
            return nil
        }

        // Subject from safe content nouns only; no nouns → no event (precision
        // over recall, and never fall back to raw text).
        let nouns = contentNouns(in: text)
        guard !nouns.isEmpty else { return nil }
        let subject = nouns.prefix(3).joined(separator: " ")
            .precomposedStringWithCompatibilityMapping  // NFKC: full/half-width unify
            .lowercased()

        let key = dedupKey(eventType: eventType, subject: subject, bucket: bucket)
        var summary = "Possible \(eventType) mentioned: \(subject)"
        if let bucket { summary += " (\(bucket))" }
        return Draft(eventType: eventType,
                     normalizedSubject: subject,
                     normalizedDateBucket: bucket,
                     dedupKey: key,
                     summary: summary,
                     confidence: confidence)
    }

    /// Contract formula: sha1(eventType + "|" + subject + "|" + (bucket ?? "none")).hex[:16]
    static func dedupKey(eventType: String, subject: String, bucket: String?) -> String {
        let material = "\(eventType)|\(subject)|\(bucket ?? "none")"
        let hex = Insecure.SHA1.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    // MARK: - Date bucket

    /// Resolve a relative/explicit date mention to a day bucket (YYYY-MM-DD)
    /// or ISO-week bucket (YYYY-Www); nil when no date reference is present.
    static func dateBucket(in lowered: String, now: Date, calendar: Calendar) -> String? {
        if lowered.contains("明後日") { return dayBucket(now, offsetDays: 2, calendar) }
        if lowered.contains("明日") || lowered.contains("tomorrow") {
            return dayBucket(now, offsetDays: 1, calendar)
        }
        if lowered.contains("今日") || lowered.contains("today") {
            return dayBucket(now, offsetDays: 0, calendar)
        }
        if lowered.contains("来週") || lowered.contains("next week") {
            return weekBucket(now.addingTimeInterval(7 * 86400))
        }
        if lowered.contains("今週") || lowered.contains("this week") || lowered.contains("週末") {
            return weekBucket(now)
        }
        // Weekday names → next occurrence within 7 days.
        let weekdays: [(String, Int)] = [  // Calendar weekday: 1=Sun … 7=Sat
            ("日曜", 1), ("月曜", 2), ("火曜", 3), ("水曜", 4), ("木曜", 5), ("金曜", 6), ("土曜", 7),
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7),
        ]
        for (name, target) in weekdays where lowered.contains(name) {
            let current = calendar.component(.weekday, from: now)
            var delta = (target - current + 7) % 7
            if delta == 0 { delta = 7 }
            return dayBucket(now, offsetDays: delta, calendar)
        }
        // Explicit N月N日.
        if let r = lowered.range(of: #"([0-9０-９]{1,2})月([0-9０-９]{1,2})日"#, options: .regularExpression) {
            let m = String(lowered[r]).precomposedStringWithCompatibilityMapping
            let nums = m.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count == 2, (1...12).contains(nums[0]), (1...31).contains(nums[1]) {
                var comps = calendar.dateComponents([.year], from: now)
                comps.month = nums[0]; comps.day = nums[1]
                if let d = calendar.date(from: comps) {
                    // A date more than a day in the past means next year.
                    let resolved = d < now.addingTimeInterval(-86400)
                        ? calendar.date(byAdding: .year, value: 1, to: d) ?? d : d
                    return dayBucket(resolved, offsetDays: 0, calendar)
                }
            }
        }
        return nil
    }

    private static func dayBucket(_ date: Date, offsetDays: Int, _ calendar: Calendar) -> String {
        let d = calendar.date(byAdding: .day, value: offsetDays, to: date) ?? date
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func weekBucket(_ date: Date) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = TimeZone.current
        let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    // MARK: - Shared noun extraction (name-redacting)

    /// Ordered content nouns in `text`.
    ///
    /// English (and other POS-tagged languages): lexicalClass nouns; words
    /// tagged as personal/place/organization names are dropped (redaction).
    ///
    /// Japanese: NLTagger's lexicalClass tags every JP token "Other"
    /// (unsupported), so fall back to token heuristics — keep tokens that
    /// carry kanji/katakana (content words; particles/grammar are pure
    /// hiragana), drop date words (the bucket captures dates), and drop any
    /// token immediately followed by an honorific (さん/様/氏/…) as a
    /// likely personal name. Residual risk: bare names without honorifics
    /// can slip through — flagged in the Phase 2 contract review.
    static func contentNouns(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var taggedNouns: [String] = []
        var tokens: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameTypeOrLexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let w = String(text[range])
            tokens.append(w)
            if tag == .noun, w.count >= 2 {
                taggedNouns.append(w.lowercased())
            }
            return true
        }
        if !taggedNouns.isEmpty { return taggedNouns }
        return japaneseContentTokens(tokens)
    }

    private static let jpHonorifics: Set<String> = ["さん", "さま", "様", "くん", "君", "氏", "先生", "ちゃん", "殿"]
    private static let jpDateWords: Set<String> = [
        "今日", "明日", "明後日", "昨日", "来週", "今週", "先週", "週末", "来月", "今月", "先月",
        "午前", "午後", "月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜", "曜日",
    ]

    /// "Alice" / "Tanaka" — first letter uppercase, the rest lowercase.
    private static func isTitleCaseLatin(_ t: String) -> Bool {
        guard let first = t.first, first.isUppercase else { return false }
        return t.dropFirst().allSatisfy { !$0.isUppercase }
    }

    private static func japaneseContentTokens(_ tokens: [String]) -> [String] {
        var out: [String] = []
        for (i, t) in tokens.enumerated() {
            guard t.count >= 2 else { continue }
            guard !jpHonorifics.contains(t), !jpDateWords.contains(t) else { continue }
            // Honorific-adjacent token = likely a personal name → redact.
            if i + 1 < tokens.count, jpHonorifics.contains(tokens[i + 1]) { continue }
            let hasKanji = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let hasKatakana = t.unicodeScalars.contains { (0x30A0...0x30FF).contains($0.value) }
            let latinLetters = t.unicodeScalars.filter { (0x41...0x7A).contains($0.value) }.count
            guard hasKanji || hasKatakana || latinLetters >= 3 else { continue }
            // Latin token inside JP text: NLTagger gives no name tags here, so
            // title-case (Alice, Tanaka) is treated as a likely proper name and
            // redacted. Lowercase words and ALL-CAPS acronyms stay.
            if !hasKanji, !hasKatakana, latinLetters >= 3, isTitleCaseLatin(t) { continue }
            out.append(t.lowercased())
        }
        return out
    }
}
