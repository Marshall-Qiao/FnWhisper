import Foundation

/// Converts only high-confidence spoken-number phrases to Arabic digits.
/// Ambiguous colloquialisms and ordinal/list markers are intentionally kept.
enum TextSpokenNumberNormalizer {
    private struct RegexMatch {
        let full: String
        let groups: [String]
        let prefix: String
        let suffix: String
    }

    private enum EnglishTokenKind {
        case unit
        case tens
        case hundred
        case scale
        case conjunction
    }

    private static let chineseDigitCharacters = "零〇一二两三四五六七八九"
    private static let chineseFractionCharacters = "零〇一二三四五六七八九"
    private static let chineseNumberCharacters = "零〇一二两三四五六七八九十百千万亿"

    private static let englishDigitWord =
        "(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)"
    private static let englishNumberWord =
        "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|and)"
    private static let englishLeftTextBoundary =
        "(?<![A-Za-z0-9_./\\\\:@#$%=+-])"
    private static let englishRightTextBoundary =
        "(?![A-Za-z0-9_./\\\\:@#$%=+-])"

    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else {
            return text
        }

        let shielded = shieldProtectedSpans(in: text)
        var result = shielded.text

        result = normalizeChineseDigitSequences(in: result)
        result = normalizeChineseVersionNumbers(in: result)
        result = normalizeChineseTimes(in: result)
        result = normalizeChineseDecimals(in: result)
        result = normalizeChineseDates(in: result)
        result = normalizeChineseScores(in: result)
        result = normalizeContextualChineseIntegers(in: result)
        result = normalizeSafeBareChineseIntegers(in: result)

        result = normalizeEnglishDigitSequences(in: result)
        result = normalizeEnglishDecimals(in: result)
        result = normalizeEnglishDates(in: result)
        result = normalizeEnglishTimes(in: result)
        result = normalizeContextualEnglishIntegers(in: result)
        result = normalizeSafeBareEnglishIntegers(in: result)

        return restoreProtectedSpans(shielded.replacements, in: result)
    }

    private static func normalizeChineseDigitSequences(in text: String) -> String {
        let digitClass = "[\(chineseDigitCharacters)0-9]"
        var result = replacing(
            pattern: "(?<![A-Za-z0-9第])\(digitClass)(?:[\\s-]*\(digitClass)){6,}(?![A-Za-z0-9])",
            in: text
        ) { match in
            chineseDigitSequence(match.full)
        }

        let prefix = "(?:手机号|手机号码|电话号码|电话|号码|编号|验证码|ID)"
        result = replacing(
            pattern: "(\(prefix)\\s*(?:是|为|[:：])?\\s*)(\(digitClass)(?:[\\s-]*\(digitClass)){2,})",
            options: [.caseInsensitive],
            in: result
        ) { match in
            guard match.groups.count == 2,
                  let digits = chineseDigitSequence(match.groups[1])
            else {
                return nil
            }
            return match.groups[0] + digits
        }
        return result
    }

    private static func normalizeChineseVersionNumbers(in text: String) -> String {
        let number = "[\(chineseNumberCharacters)]+"
        return replacing(
            pattern: "((?:版本|version)\\s*)(\(number)(?:点\(number)){1,3})",
            options: [.caseInsensitive],
            in: text
        ) { match in
            guard match.groups.count == 2 else {
                return nil
            }
            let segments = match.groups[1].split(separator: "点")
            let values = segments.compactMap {
                chineseInteger(String($0)).map(String.init)
            }
            guard values.count == segments.count else {
                return nil
            }
            return match.groups[0] + values.joined(separator: ".")
        }
    }

    private static func normalizeChineseTimes(in text: String) -> String {
        let number = "[\(chineseNumberCharacters)]+"
        var result = replacing(
            pattern: "(?<!第)(\(number))点(\(number))分",
            in: text
        ) { match in
            guard match.groups.count == 2,
                  let hour = chineseInteger(match.groups[0]),
                  let minute = chineseInteger(match.groups[1]),
                  (0...23).contains(hour),
                  (0...59).contains(minute)
            else {
                return nil
            }
            return "\(hour)点\(minute)分"
        }

        result = replacing(
            pattern: "(?<!第)(\(number))点半",
            in: result
        ) { match in
            guard let value = match.groups.first.flatMap(chineseInteger),
                  (0...23).contains(value)
            else {
                return nil
            }
            return "\(value)点半"
        }

        let timeCue = "(?:凌晨|早上|上午|中午|下午|晚上|今晚|明早)"
        result = replacing(
            pattern: "(\(timeCue)\\s*)(\(number))点",
            in: result
        ) { match in
            guard match.groups.count == 2,
                  let value = chineseInteger(match.groups[1]),
                  (0...23).contains(value)
            else {
                return nil
            }
            return "\(match.groups[0])\(value)点"
        }

        let schedulingCue = "(?:改到|定在|安排在|不对[\\s，,。；;：:]*是)"
        result = replacing(
            pattern: "(\(schedulingCue)\\s*)(\(number))点",
            in: result
        ) { match in
            guard match.groups.count == 2,
                  let value = chineseInteger(match.groups[1]),
                  (0...23).contains(value)
            else {
                return nil
            }
            return "\(match.groups[0])\(value)点"
        }

        result = replacing(
            pattern: "(?<!第)(\(number))(?=点(?:钟|开会|开始|结束|发布|出发|到达|提醒|集合))",
            in: result
        ) { match in
            guard let value = match.groups.first.flatMap(chineseInteger),
                  (0...23).contains(value)
            else {
                return nil
            }
            return String(value)
        }
        return result
    }

    private static func normalizeChineseDecimals(in text: String) -> String {
        let integer = "[\(chineseNumberCharacters)]+"
        let fraction = "[\(chineseFractionCharacters)]+"
        return replacing(
            pattern: "(?<!第)(\(integer))点(\(fraction))([万亿]?)",
            in: text
        ) { match in
            guard match.groups.count == 3,
                  !match.suffix.hasPrefix("分"),
                  !match.suffix.hasPrefix("钟"),
                  !hasTimeCueImmediatelyBefore(match.prefix),
                  let whole = chineseInteger(match.groups[0]),
                  let fractional = chineseDigitSequence(
                    match.groups[1],
                    preservingHyphens: false
                  )
            else {
                return nil
            }
            return "\(whole).\(fractional)\(match.groups[2])"
        }
    }

    private static func normalizeChineseDates(in text: String) -> String {
        var result = replacing(
            pattern: "(?<!第)([\(chineseDigitCharacters)]{2,4})(?=年)",
            in: text
        ) { match in
            chineseDigitSequence(match.full, preservingHyphens: false)
        }

        result = replacing(
            pattern: "(?<!第)([\(chineseNumberCharacters)]+)(?=(?:月|日|号))",
            in: result
        ) { match in
            return chineseInteger(match.full).map(String.init)
        }
        return result
    }

    private static func normalizeChineseScores(in text: String) -> String {
        replacing(
            pattern: "(?<!第)([\(chineseNumberCharacters)]+)比([\(chineseNumberCharacters)]+)",
            in: text
        ) { match in
            guard match.groups.count == 2,
                  let first = chineseInteger(match.groups[0]),
                  let second = chineseInteger(match.groups[1])
            else {
                return nil
            }
            return "\(first)比\(second)"
        }
    }

    private static func normalizeContextualChineseIntegers(in text: String) -> String {
        let number = "[\(chineseNumberCharacters)]+"
        let prefix = "(?:版本|数量|编号|序号|号码|验证码|端口|比分|得分|价格|金额|时长)"
        var result = replacing(
            pattern: "(\(prefix)\\s*(?:是|为|[:：])?\\s*)(\(number))",
            in: text
        ) { match in
            guard match.groups.count == 2,
                  let value = chineseInteger(match.groups[1])
            else {
                return nil
            }
            return match.groups[0] + String(value)
        }

        let suffix = "(?:个|件|项|条|次|人|份|台|本|张|套|页|章|天|周|个月|年|小时|分钟|秒|毫秒|元|美元|加元|%|GB|MB|KB|B|tokens?)"
        result = replacing(
            pattern: "(?<!第)(\(number))(?=\(suffix))",
            options: [.caseInsensitive],
            in: result
        ) { match in
            if match.full == "一",
               match.suffix.hasPrefix("个"),
               (match.suffix.hasPrefix("个是")
                    || match.prefix.hasSuffix("还有")
                    || match.prefix.hasSuffix("另")) {
                return nil
            }
            return chineseInteger(match.full).map(String.init)
        }
        return result
    }

    private static func normalizeSafeBareChineseIntegers(in text: String) -> String {
        replacing(
            pattern: "(?<!第)[\(chineseNumberCharacters)]+",
            in: text
        ) { match in
            let token = match.full
            let containsUnit = token.contains { "十百千万亿".contains($0) }
            guard containsUnit else {
                return nil
            }

            let characters = Array(token)
            let shortPower = characters.count == 2
                && chineseDigit(characters[0]) != nil
                && "百千万亿".contains(characters[1])
            guard characters.count >= 3 || shortPower,
                  let value = chineseInteger(token)
            else {
                return nil
            }
            return String(value)
        }
    }

    private static func normalizeEnglishDigitSequences(in text: String) -> String {
        var result = replacing(
            pattern: "\(englishLeftTextBoundary)\(englishDigitWord)(?:[\\s-]+\(englishDigitWord)){6,}\(englishRightTextBoundary)",
            options: [.caseInsensitive],
            in: text
        ) { match in
            englishDigitSequence(match.full)
        }

        let prefix = "(?:phone(?: number)?|mobile(?: number)?|telephone(?: number)?|number|verification code|ID)"
        result = replacing(
            pattern: "\(englishLeftTextBoundary)(\(prefix)\\s*(?:is|[:：])?\\s*)(\(englishDigitWord)(?:[\\s-]+\(englishDigitWord)){2,})\(englishRightTextBoundary)",
            options: [.caseInsensitive],
            in: result
        ) { match in
            guard match.groups.count == 2,
                  let digits = englishDigitSequence(match.groups[1])
            else {
                return nil
            }
            return match.groups[0] + digits
        }
        return result
    }

    private static func normalizeEnglishDecimals(in text: String) -> String {
        let phrase = "\(englishNumberWord)(?:[\\s-]+\(englishNumberWord))*"
        let fractional = "\(englishDigitWord)(?:[\\s-]+\(englishDigitWord))*"
        return replacing(
            pattern: "\(englishLeftTextBoundary)(\(phrase))\\s+point\\s+(\(fractional))\(englishRightTextBoundary)",
            options: [.caseInsensitive],
            in: text
        ) { match in
            guard match.groups.count == 2,
                  let whole = englishInteger(match.groups[0]),
                  let fraction = englishDigitSequence(match.groups[1])
            else {
                return nil
            }
            return "\(whole).\(fraction)"
        }
    }

    private static func normalizeEnglishDates(in text: String) -> String {
        let month = "(?:January|February|March|April|May|June|July|August|September|October|November|December)"
        return replacing(
            pattern: "\(englishLeftTextBoundary)(\(month)\\s+)([A-Za-z]+(?:-[A-Za-z]+)?)\(englishRightTextBoundary)",
            options: [.caseInsensitive],
            in: text
        ) { match in
            guard match.groups.count == 2,
                  let day = englishDateOrdinal(match.groups[1])
            else {
                return nil
            }
            return match.groups[0] + String(day)
        }
    }

    private static func normalizeEnglishTimes(in text: String) -> String {
        let phrase = "\(englishNumberWord)(?:[\\s-]+\(englishNumberWord))*"
        return replacing(
            pattern: "\(englishLeftTextBoundary)((?:at|by|around)\\s+)(\(phrase))\(englishRightTextBoundary)",
            options: [.caseInsensitive],
            in: text
        ) { match in
            guard match.groups.count == 2,
                  !(englishWords(match.groups[1]).count == 1
                    && match.suffix
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                        .hasPrefix("point")),
                  let value = englishTime(match.groups[1])
            else {
                return nil
            }
            return match.groups[0] + value
        }
    }

    private static func normalizeContextualEnglishIntegers(in text: String) -> String {
        let phrase = "\(englishNumberWord)(?:[\\s-]+\(englishNumberWord))*"
        let prefix = "(?:version|count|quantity|number|ID|port|score|issue|ticket|PR)"
        var result = replacing(
            pattern: "\(englishLeftTextBoundary)(\(prefix)\\s*(?:is|[:：])?\\s*)(\(phrase))\(englishRightTextBoundary)",
            options: [.caseInsensitive],
            in: text
        ) { match in
            guard match.groups.count == 2,
                  let value = englishInteger(match.groups[1])
            else {
                return nil
            }
            return match.groups[0] + String(value)
        }

        let suffix = "(?:items?|times?|people|days?|weeks?|months?|years?|hours?|minutes?|seconds?|milliseconds?|dollars?|percent|tokens?|GB|MB|KB|B)"
        result = replacing(
            pattern: "\(englishLeftTextBoundary)(\(phrase))(?=\\s+\(suffix)\(englishRightTextBoundary))",
            options: [.caseInsensitive],
            in: result
        ) { match in
            englishInteger(match.full).map(String.init)
        }
        return result
    }

    private static func normalizeSafeBareEnglishIntegers(in text: String) -> String {
        let phrase = "\(englishNumberWord)(?:[\\s-]+\(englishNumberWord))*"
        return replacing(
            pattern: "\(englishLeftTextBoundary)\(phrase)\(englishRightTextBoundary)",
            options: [.caseInsensitive],
            in: text
        ) { match in
            let words = englishWords(match.full)
            let hasScale = words.contains {
                ["hundred", "thousand", "million", "billion"].contains($0)
            }
            let startsWithTens = words.first.flatMap(englishTens) != nil
            guard hasScale || startsWithTens,
                  let value = englishInteger(match.full)
            else {
                return nil
            }
            return String(value)
        }
    }

    private static func chineseInteger(_ text: String) -> Int? {
        let characters = Array(text)
        guard !characters.isEmpty else {
            return nil
        }

        let hasUnit = characters.contains { "十百千万亿".contains($0) }
        if !hasUnit {
            let values = characters.compactMap(chineseDigit)
            guard values.count == characters.count else {
                return nil
            }
            return values.reduce(0) { $0 * 10 + $1 }
        }

        if let first = characters.first, "百千万亿".contains(first) {
            return nil
        }
        if hasAmbiguousChineseShorthand(characters) {
            return nil
        }

        let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
        let largeUnits: [Character: Int] = ["万": 10_000, "亿": 100_000_000]
        var total = 0
        var section = 0
        var pendingDigit: Int?
        var lastSmallUnit = Int.max
        var lastLargeUnit = Int.max
        var previousCharacter: Character?

        for character in characters {
            if let digit = chineseDigit(character) {
                if let previousCharacter,
                   chineseDigit(previousCharacter) != nil,
                   previousCharacter != "零",
                   previousCharacter != "〇" {
                    return nil
                }
                pendingDigit = digit
            } else if let unit = smallUnits[character] {
                guard unit < lastSmallUnit else {
                    return nil
                }
                if pendingDigit == 0 {
                    return nil
                }
                section += max(pendingDigit ?? 0, 1) * unit
                pendingDigit = nil
                lastSmallUnit = unit
            } else if let unit = largeUnits[character] {
                guard unit < lastLargeUnit else {
                    return nil
                }
                section += pendingDigit ?? 0
                guard section > 0 else {
                    return nil
                }
                total += section * unit
                section = 0
                pendingDigit = nil
                lastSmallUnit = Int.max
                lastLargeUnit = unit
            } else {
                return nil
            }
            previousCharacter = character
        }
        return total + section + (pendingDigit ?? 0)
    }

    private static func hasAmbiguousChineseShorthand(
        _ characters: [Character]
    ) -> Bool {
        guard let last = characters.last,
              let lastDigit = chineseDigit(last),
              lastDigit != 0,
              let unitIndex = characters.lastIndex(where: {
                  "百千万亿".contains($0)
              })
        else {
            return false
        }
        let suffix = characters[characters.index(after: unitIndex)...]
        let statesAPlaceValue = suffix.contains { "十百千".contains($0) }
        return !suffix.contains("零")
            && !suffix.contains("〇")
            && !statesAPlaceValue
    }

    private static func chineseDigit(_ character: Character) -> Int? {
        switch character {
        case "零", "〇": return 0
        case "一": return 1
        case "二", "两": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "七": return 7
        case "八": return 8
        case "九": return 9
        default: return nil
        }
    }

    private static func chineseDigitSequence(
        _ text: String,
        preservingHyphens: Bool = true
    ) -> String? {
        var result = ""
        var digitCount = 0
        for character in text {
            if let value = chineseDigit(character) {
                result.append(String(value))
                digitCount += 1
            } else if character.isNumber {
                result.append(character)
                digitCount += 1
            } else if character == "-", preservingHyphens {
                result.append(character)
            } else if character.isWhitespace {
                continue
            } else {
                return nil
            }
        }
        return digitCount > 0 ? result : nil
    }

    private static func englishInteger(_ text: String) -> Int? {
        let words = englishWords(text)
        guard !words.isEmpty else {
            return nil
        }

        var total = 0
        var current = 0
        var lastKind: EnglishTokenKind?
        var lastScale = Int.max
        var sawValue = false

        for word in words {
            if word == "and" {
                guard sawValue, lastKind != .conjunction else {
                    return nil
                }
                lastKind = .conjunction
                continue
            }
            if let value = englishUnit(word) {
                if lastKind == .unit {
                    return nil
                }
                current += value
                lastKind = .unit
                sawValue = true
            } else if let value = englishTens(word) {
                if lastKind == .unit || lastKind == .tens {
                    return nil
                }
                current += value
                lastKind = .tens
                sawValue = true
            } else if word == "hundred" {
                guard current > 0,
                      current < 10,
                      lastKind == .unit
                else {
                    return nil
                }
                current *= 100
                lastKind = .hundred
            } else if let scale = englishScale(word) {
                guard current > 0, scale < lastScale else {
                    return nil
                }
                total += current * scale
                current = 0
                lastScale = scale
                lastKind = .scale
                sawValue = true
            } else {
                return nil
            }
        }
        guard sawValue, lastKind != .conjunction else {
            return nil
        }
        return total + current
    }

    private static func englishTime(_ text: String) -> String? {
        let words = englishWords(text)
        guard !words.isEmpty else {
            return nil
        }
        if let hour = englishInteger(text), (0...23).contains(hour) {
            return String(hour)
        }
        guard let hour = englishUnit(words[0]),
              (0...23).contains(hour),
              words.count >= 2
        else {
            return nil
        }

        let minuteWords = Array(words.dropFirst())
        let minute: Int?
        if minuteWords.first == "oh" {
            let digits = minuteWords.compactMap(englishDigit)
            minute = digits.count == minuteWords.count
                ? Int(digits.map(String.init).joined())
                : nil
        } else {
            minute = englishInteger(minuteWords.joined(separator: " "))
        }
        guard let minute, (0...59).contains(minute) else {
            return nil
        }
        return String(format: "%d:%02d", hour, minute)
    }

    private static func englishWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }

    private static func englishDigitSequence(_ text: String) -> String? {
        let words = englishWords(text)
        let digits = words.compactMap(englishDigit)
        guard !digits.isEmpty, digits.count == words.count else {
            return nil
        }
        return digits.map(String.init).joined()
    }

    private static func englishDigit(_ word: String) -> Int? {
        switch word.lowercased() {
        case "zero", "oh": return 0
        case "one": return 1
        case "two": return 2
        case "three": return 3
        case "four": return 4
        case "five": return 5
        case "six": return 6
        case "seven": return 7
        case "eight": return 8
        case "nine": return 9
        default: return nil
        }
    }

    private static func englishUnit(_ word: String) -> Int? {
        switch word.lowercased() {
        case "zero": return 0
        case "one": return 1
        case "two": return 2
        case "three": return 3
        case "four": return 4
        case "five": return 5
        case "six": return 6
        case "seven": return 7
        case "eight": return 8
        case "nine": return 9
        case "ten": return 10
        case "eleven": return 11
        case "twelve": return 12
        case "thirteen": return 13
        case "fourteen": return 14
        case "fifteen": return 15
        case "sixteen": return 16
        case "seventeen": return 17
        case "eighteen": return 18
        case "nineteen": return 19
        default: return nil
        }
    }

    private static func englishTens(_ word: String) -> Int? {
        switch word.lowercased() {
        case "twenty": return 20
        case "thirty": return 30
        case "forty": return 40
        case "fifty": return 50
        case "sixty": return 60
        case "seventy": return 70
        case "eighty": return 80
        case "ninety": return 90
        default: return nil
        }
    }

    private static func englishScale(_ word: String) -> Int? {
        switch word.lowercased() {
        case "thousand": return 1_000
        case "million": return 1_000_000
        case "billion": return 1_000_000_000
        default: return nil
        }
    }

    private static func englishDateOrdinal(_ word: String) -> Int? {
        let values: [String: Int] = [
            "first": 1, "second": 2, "third": 3, "fourth": 4,
            "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
            "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
            "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
            "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
            "nineteenth": 19, "twentieth": 20, "twenty-first": 21,
            "twenty-second": 22, "twenty-third": 23,
            "twenty-fourth": 24, "twenty-fifth": 25,
            "twenty-sixth": 26, "twenty-seventh": 27,
            "twenty-eighth": 28, "twenty-ninth": 29,
            "thirtieth": 30, "thirty-first": 31,
        ]
        return values[word.lowercased()]
    }

    private static func hasTimeCueImmediatelyBefore(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["凌晨", "早上", "上午", "中午", "下午", "晚上", "今晚", "明早"]
            .contains { trimmed.hasSuffix($0) }
    }

    private static func shieldProtectedSpans(
        in text: String
    ) -> (text: String, replacements: [(String, String)]) {
        var result = text
        var replacements: [(String, String)] = []

        let protectedPatterns: [(String, NSRegularExpression.Options)] = [
            ("```[\\s\\S]*?```|`[^`\\n]+`", []),
            (
                "\\b(?:https?|ftp)://[^\\s<>\\\"'`，。；！？]+|\\bwww\\.[^\\s<>\\\"'`，。；！？]+",
                [.caseInsensitive]
            ),
            (
                "(?m)(?:^|\\n)[ \\t]*\\$[ \\t]*(?:sudo[ \\t]+)?[A-Za-z0-9_./-]+(?:[ \\t]+[^\\n]*)?",
                [.caseInsensitive]
            ),
            (
                "(?m)(?:^|\\n)[ \\t]*(?:sudo[ \\t]+)?git[ \\t]+(?:add|branch|checkout|cherry-pick|clone|commit|diff|fetch|init|log|merge|pull|push|rebase|reset|restore|show|status|switch|tag|worktree)\\b[^\\n]*",
                [.caseInsensitive]
            ),
            (
                "(?m)(?:^|\\n)[ \\t]*(?:(?:let|var|const)[ \\t]+[A-Za-z_][A-Za-z0-9_]*[ \\t]*(?::[^=\\n]+)?=|(?:func|function|def)[ \\t]+[A-Za-z_][A-Za-z0-9_]*[ \\t]*\\()[^\\n]*",
                []
            ),
            (
                "(?<![A-Za-z0-9])(?:(?:~|\\.{1,2})/|/(?!/)|(?:[A-Za-z0-9._~-]+/)+)[^\\s<>\\\"'`，。；！？]+",
                []
            ),
            (
                "(?<![A-Za-z0-9])(?:[A-Za-z]:\\\\|\\\\\\\\)[^\\s<>\\\"'`，。；！？]+",
                []
            ),
            (
                "第[\(chineseNumberCharacters)]+(?:项|条|点|步|个|次|章|页|名|位)?|(?:星期|礼拜|周)[一二三四五六日天]",
                []
            ),
        ]

        for (pattern, options) in protectedPatterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: options
            ) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in expression.matches(in: result, range: range).reversed() {
                guard let sourceRange = Range(match.range, in: result) else {
                    continue
                }
                let original = String(result[sourceRange])
                let marker = "\u{E000}FNSHIELD\(replacements.count)\u{E001}"
                result.replaceSubrange(sourceRange, with: marker)
                replacements.append((marker, original))
            }
        }
        return (result, replacements)
    }

    private static func restoreProtectedSpans(
        _ replacements: [(String, String)],
        in text: String
    ) -> String {
        replacements.reduce(text) { result, replacement in
            result.replacingOccurrences(
                of: replacement.0,
                with: replacement.1
            )
        }
    }

    private static func replacing(
        pattern: String,
        options: NSRegularExpression.Options = [],
        in text: String,
        transform: (RegexMatch) -> String?
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return text
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let edits: [(NSRange, String)] = expression.matches(
            in: text,
            range: fullRange
        ).compactMap { match in
            guard let range = Range(match.range, in: text) else {
                return nil
            }
            let groups = (1..<match.numberOfRanges).map { index -> String in
                guard match.range(at: index).location != NSNotFound,
                      let groupRange = Range(match.range(at: index), in: text)
                else {
                    return ""
                }
                return String(text[groupRange])
            }
            let value = RegexMatch(
                full: String(text[range]),
                groups: groups,
                prefix: String(text[..<range.lowerBound]),
                suffix: String(text[range.upperBound...])
            )
            return transform(value).map { (match.range, $0) }
        }

        var result = text
        for (range, replacement) in edits.reversed() {
            guard let target = Range(range, in: result) else {
                continue
            }
            result.replaceSubrange(target, with: replacement)
        }
        return result
    }
}
