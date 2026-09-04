import Foundation

/// Deterministic, offline post-processing for dictated e-mail text.
///
/// Whisper transcribes an e-mail as a single run-on paragraph. This formatter
/// inserts paragraph breaks around a detected greeting and a detected sign-off,
/// without ever changing, adding, or removing a word. No LLM, no network.
enum EmailParagraphFormatter {

    /// Greeting keywords recognized only at the very start of the text (after trimming
    /// leading whitespace). Case-insensitive, whole-word match. When several keywords
    /// match at the start, the longest one wins.
    static let greetings: [String] = [
        // German
        "moin moin", "moin", "hallo", "hi there", "hi", "hey there", "hey", "servus",
        "grüß dich", "grüß gott",
        "guten morgen", "guten tag", "guten abend", "mahlzeit",
        "sehr geehrte", "sehr geehrter", "sehr geehrtes",
        "liebe", "lieber", "liebes",
        // English
        "hello", "dear",
        "good morning", "good afternoon", "good evening"
    ]

    /// Sign-off phrases recognized near the end of the text. Case-insensitive,
    /// whole-word match. ü/ue and ß/ss spelling variants are accepted. When several
    /// phrases overlap (e.g. "viele grüße" and "grüße"), the longest/most specific
    /// one wins.
    static let signOffs: [String] = [
        // German
        "mit freundlichen grüßen", "mit freundlichem gruß", "mit besten grüßen",
        "mit herzlichen grüßen", "mit lieben grüßen",
        "ganz liebe grüße", "freundliche grüße", "viele grüße", "liebe grüße",
        "beste grüße", "herzliche grüße", "schöne grüße", "sonnige grüße",
        "alles liebe", "alles gute",
        "bis nächste woche",
        "bis montag", "bis dienstag", "bis mittwoch", "bis donnerstag",
        "bis freitag", "bis samstag", "bis sonntag",
        "bis bald", "bis dann", "bis morgen", "bis später",
        "schönes wochenende", "schönen tag noch", "einen schönen tag", "schönen abend",
        "lg", "glg", "vg", "mfg", "gruß", "grüße",
        // English
        "kind regards", "best regards", "warm regards", "regards",
        "best wishes", "all the best", "best", "cheers",
        "thank you", "many thanks", "thanks",
        "take care", "talk soon", "see you",
        "yours sincerely", "sincerely"
    ]

    /// Sentence-ending markers used to locate the start of the sentence a sign-off
    /// phrase sits in (rule R2c, "sonst" branch).
    private static let sentenceEndMarkers = [". ", "! ", "? "]

    /// Abbreviations whose trailing "." is not a sentence- or clause-ending period.
    /// Matched as the whole word immediately preceding a candidate "." (case-insensitive).
    private static let abbreviationsBeforePeriod: [String] = [
        "z.b", "u.a", "d.h", "u.u", "o.ä", "o.ae",
        "dr", "prof", "hr", "fr", "nr", "str", "etc", "usw", "ggf", "bzw", "ca",
        "inkl", "exkl", "evtl", "zzgl"
    ]

    /// Clause-boundary markers that let a sign-off break directly before the phrase
    /// (rule R2c). Includes both a hyphen and an en dash spaced clause break.
    private static let clauseBoundaryMarkers = [". ", "! ", "? ", ", ", "; ", " \u{2013} ", " - "]

    // MARK: - Public API

    /// Inserts paragraph breaks around a detected greeting and sign-off. Never changes words.
    static func format(_ text: String) -> String {
        // R0: leave already-formatted (idempotent) or very short text untouched.
        guard !text.contains("\n") else { return text }
        guard wordCount(text[...]) >= 4 else { return text }

        let signOffPlan = resolveSignOff(in: text)

        // R3: the greeting only gets its own paragraph if a sign-off was found,
        // or the text is long enough to not be a short chat message.
        let greetingAllowed = signOffPlan != nil || wordCount(text[...]) >= 25
        let greetingPunctuationIndex: String.Index? =
            greetingAllowed ? findGreetingPunctuation(in: text) : nil

        guard greetingPunctuationIndex != nil || signOffPlan != nil else { return text }

        var edits: [Edit] = []
        if let punctIndex = greetingPunctuationIndex {
            edits.append(greetingEdit(at: punctIndex, in: text))
        }
        if let plan = signOffPlan {
            edits.append(contentsOf: signOffEdits(for: plan, in: text))
        }

        return apply(edits, to: text)
    }

    // MARK: - Word counting

    /// Counts whitespace-delimited tokens that contain at least one letter or digit.
    /// A token made up only of punctuation (e.g. a lone ".") is not a word.
    private static func wordCount(_ s: Substring) -> Int {
        meaningfulWords(s).count
    }

    private static func meaningfulWords(_ s: Substring) -> [Substring] {
        s.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func firstNonWhitespaceIndex(_ s: String) -> String.Index {
        s.firstIndex(where: { !$0.isWhitespace }) ?? s.startIndex
    }

    /// Whether the "." at `periodIndex` is a genuine sentence-/clause-ending period,
    /// as opposed to one embedded in a decimal or time number ("14.30", "20.000") or
    /// following a known abbreviation ("Dr.", "Prof.", "z.B."). Used to keep the
    /// greeting-window scan and the sign-off sentence-start search from mistaking
    /// such a period for real punctuation.
    private static func isSentenceTerminatingPeriod(at periodIndex: String.Index, in text: String) -> Bool {
        // A period followed directly by a digit is part of a number, not a
        // sentence/clause end ("14.30 Uhr", "20.000 Euro").
        let afterIndex = text.index(after: periodIndex)
        if afterIndex < text.endIndex, text[afterIndex].isNumber {
            return false
        }

        // A period whose immediately preceding word is a known abbreviation is not
        // a sentence/clause end ("Dr. Schmidt", "z.B. dieses").
        for abbreviation in abbreviationsBeforePeriod {
            guard let start = text.index(periodIndex, offsetBy: -abbreviation.count, limitedBy: text.startIndex) else { continue }
            guard text[start..<periodIndex].compare(abbreviation, options: .caseInsensitive) == .orderedSame else { continue }
            let isWholeWord = start == text.startIndex || !isWordChar(text[text.index(before: start)])
            if isWholeWord { return false }
        }

        return true
    }

    // MARK: - Phrase variants (ü/ue, ß/ss)

    /// Expands a phrase into its ü/ue and ß/ss spelling variants (e.g. "grüße" also
    /// matches "gruesse", "grüsse", "gruesse").
    private static func variants(of phrase: String) -> [String] {
        var results: Set<String> = [phrase]
        if phrase.contains("ü") {
            for v in results { results.insert(v.replacingOccurrences(of: "ü", with: "ue")) }
        }
        if phrase.contains("ß") {
            for v in results { results.insert(v.replacingOccurrences(of: "ß", with: "ss")) }
        }
        return Array(results)
    }

    // MARK: - Whole-word phrase matching

    /// Returns the end index of the longest phrase from `phrases` that matches, as a
    /// whole word (case-insensitive), starting exactly at `index`. Nil if none match.
    private static func matchesAnyPhrase(_ phrases: [String], at index: String.Index, in text: String) -> String.Index? {
        var bestEnd: String.Index?
        for phrase in phrases {
            for variant in variants(of: phrase) {
                guard let end = text.index(index, offsetBy: variant.count, limitedBy: text.endIndex) else { continue }
                guard text[index..<end].compare(variant, options: .caseInsensitive) == .orderedSame else { continue }
                guard end == text.endIndex || !isWordChar(text[end]) else { continue }
                if bestEnd == nil || end > bestEnd! {
                    bestEnd = end
                }
            }
        }
        return bestEnd
    }

    /// Returns every whole-word (case-insensitive) occurrence of `phrase` in `text`.
    private static func findAll(_ phrase: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: phrase, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let beforeOK = r.lowerBound == text.startIndex || !isWordChar(text[text.index(before: r.lowerBound)])
            let afterOK = r.upperBound == text.endIndex || !isWordChar(text[r.upperBound])
            if beforeOK && afterOK {
                ranges.append(r)
            }
            searchStart = text.index(after: r.lowerBound)
        }
        return ranges
    }

    /// All occurrences of any phrase (and its ü/ß variants) from `phrases` in `text`.
    private static func allMatches(for phrases: [String], in text: String) -> [Range<String.Index>] {
        var all: [Range<String.Index>] = []
        for phrase in phrases {
            for variant in variants(of: phrase) {
                all.append(contentsOf: findAll(variant, in: text))
            }
        }
        return all
    }

    /// Drops matches that are fully contained inside a longer match (e.g. "grüße" is
    /// dropped when "viele grüße" also matched the same words).
    private static func removeSubsumed(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        ranges.filter { r in
            !ranges.contains { other in
                other != r && other.lowerBound <= r.lowerBound && other.upperBound >= r.upperBound
            }
        }
    }

    // MARK: - R1: Greeting

    /// Finds the punctuation character (",", "." or "!") that ends the greeting
    /// phrase at the start of `text`, or nil if there is no greeting.
    private static func findGreetingPunctuation(in text: String) -> String.Index? {
        let contentStart = firstNonWhitespaceIndex(text)
        guard contentStart < text.endIndex else { return nil }

        // A phrase that itself starts like a sign-off ("Liebe Grüße" at the very
        // start) is never a greeting.
        guard matchesAnyPhrase(signOffs, at: contentStart, in: text) == nil else { return nil }

        guard let keywordEnd = matchesAnyPhrase(greetings, at: contentStart, in: text) else { return nil }

        let remainder = text[keywordEnd...]
        let words = meaningfulWords(remainder)
        let windowEnd = words.prefix(6).last?.endIndex ?? keywordEnd

        guard keywordEnd < windowEnd else { return nil }

        // Scan for the first ',' or '!' or genuine sentence-ending '.' -- skipping
        // over periods that are part of an abbreviation ("Dr.") or a decimal/time
        // number ("14.30") and continuing the scan for the next candidate instead.
        var idx = keywordEnd
        while idx < windowEnd {
            let c = text[idx]
            if c == "," || c == "!" {
                return idx
            }
            if c == "." && isSentenceTerminatingPeriod(at: idx, in: text) {
                return idx
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func greetingEdit(at punctIndex: String.Index, in text: String) -> Edit {
        let afterPunct = text.index(after: punctIndex)
        var resume = afterPunct
        while resume < text.endIndex, text[resume].isWhitespace {
            resume = text.index(after: resume)
        }
        return Edit(range: afterPunct..<resume, replacement: "\n\n")
    }

    // MARK: - R2: Sign-off

    private struct SignOffPlan {
        let breakpoint: String.Index
        let phraseRange: Range<String.Index>
    }

    /// Locates the last (rightmost) non-subsumed sign-off candidate and validates it
    /// against all of rule R2's conditions. Returns nil if no valid sign-off is found.
    private static func resolveSignOff(in text: String) -> SignOffPlan? {
        guard !text.isEmpty else { return nil }
        let candidates = removeSubsumed(allMatches(for: signOffs, in: text))
        guard let phraseRange = candidates.max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }

        // a) end region: within the last 40% of the text, or the last 120 characters
        //    -- whichever region is larger.
        let totalChars = text.count
        let startOffset = text.distance(from: text.startIndex, to: phraseRange.lowerBound)
        let regionSize = max(Double(totalChars) * 0.4, 120.0)
        guard Double(totalChars - startOffset) <= regionSize else { return nil }

        // b) at most 4 (meaningful) words follow the phrase.
        guard wordCount(text[phraseRange.upperBound...]) <= 4 else { return nil }

        // c) breakpoint.
        let contentStart = firstNonWhitespaceIndex(text)
        if phraseRange.lowerBound == contentStart || hasClauseBoundary(before: phraseRange.lowerBound, in: text) {
            return SignOffPlan(breakpoint: phraseRange.lowerBound, phraseRange: phraseRange)
        }

        let sentenceStart = findSentenceStart(before: phraseRange.lowerBound, in: text, contentStart: contentStart)
        guard wordCount(text[sentenceStart..<phraseRange.lowerBound]) <= 8 else { return nil }
        return SignOffPlan(breakpoint: sentenceStart, phraseRange: phraseRange)
    }

    private static func hasClauseBoundary(before index: String.Index, in text: String) -> Bool {
        for marker in clauseBoundaryMarkers {
            guard let markerStart = text.index(index, offsetBy: -marker.count, limitedBy: text.startIndex) else { continue }
            if text[markerStart..<index] == marker { return true }
        }
        return false
    }

    private static func findSentenceStart(before index: String.Index, in text: String, contentStart: String.Index) -> String.Index {
        var best: String.Index?
        for marker in sentenceEndMarkers {
            var searchRange = text.startIndex..<index
            while let r = text.range(of: marker, options: [], range: searchRange) {
                // Skip a ". " marker whose period belongs to an abbreviation ("Dr. ")
                // rather than a genuine sentence end; keep searching further back.
                let isFakePeriodBoundary = marker.hasPrefix(".") && !isSentenceTerminatingPeriod(at: r.lowerBound, in: text)
                if !isFakePeriodBoundary, best == nil || r.upperBound > best! {
                    best = r.upperBound
                }
                searchRange = r.upperBound..<index
            }
        }
        return best ?? contentStart
    }

    /// Builds the edits that realize a validated sign-off plan: the paragraph break
    /// before it, the capitalized first letter of the new line, and the cleaned-up
    /// tail (punctuation and name handling).
    private static func signOffEdits(for plan: SignOffPlan, in text: String) -> [Edit] {
        var edits: [Edit] = []
        let contentStart = firstNonWhitespaceIndex(text)

        if plan.breakpoint > contentStart {
            var trimStart = plan.breakpoint
            func stepBackWhitespace() -> Bool {
                guard trimStart > text.startIndex else { return false }
                let prev = text.index(before: trimStart)
                guard text[prev].isWhitespace else { return false }
                trimStart = prev
                return true
            }
            while stepBackWhitespace() {}
            if trimStart > text.startIndex {
                let prev = text.index(before: trimStart)
                if text[prev] == "," {
                    trimStart = prev
                    while stepBackWhitespace() {}
                }
            }
            edits.append(Edit(range: trimStart..<plan.breakpoint, replacement: "\n\n"))
        }

        if plan.breakpoint < text.endIndex {
            let c = text[plan.breakpoint]
            edits.append(Edit(
                range: plan.breakpoint..<text.index(after: plan.breakpoint),
                replacement: String(c).uppercased()
            ))
        }

        edits.append(Edit(
            range: plan.phraseRange.upperBound..<text.endIndex,
            replacement: signOffTail(text[plan.phraseRange.upperBound...])
        ))

        return edits
    }

    /// Cleans up the text after the sign-off phrase: drops one adjacent "," or "."
    /// (an adjacent "!" is kept), puts the name on its own line, and drops one
    /// trailing "." at the very end (a trailing "!" is kept).
    private static func signOffTail(_ tail: Substring) -> String {
        var out = ""
        var idx = tail.startIndex

        if idx < tail.endIndex, tail[idx] == "," || tail[idx] == "." {
            idx = tail.index(after: idx)
        } else if idx < tail.endIndex, tail[idx] == "!" {
            out += "!"
            idx = tail.index(after: idx)
        }

        while idx < tail.endIndex, tail[idx].isWhitespace {
            idx = tail.index(after: idx)
        }

        let namePart = tail[idx...]
        if !namePart.isEmpty {
            out += "\n"
            var nameString = String(namePart)
            if nameString.hasSuffix(".") {
                nameString.removeLast()
            }
            out += nameString
        }
        return out
    }

    // MARK: - Edit application

    private struct Edit {
        let range: Range<String.Index>
        let replacement: String
    }

    private static func apply(_ edits: [Edit], to text: String) -> String {
        let sorted = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var cursor = text.startIndex
        for edit in sorted {
            guard edit.range.lowerBound >= cursor else { continue }
            result += text[cursor..<edit.range.lowerBound]
            result += edit.replacement
            cursor = edit.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
