import Foundation
import os

private let mailHistoryLogger = Logger(subsystem: "app.blitztext.mac", category: "MailHistory")

/// A mail Ben received from the other party (recipient of a new mail, sender
/// of the mail being answered): the newest one that addresses Ben, else the
/// newest. Used only to decide Du/Sie and to get names right.
struct MailHistory: Equatable {
    /// Sender as Mail reports it: display name plus address.
    var sender: String
    var dateReceived: String
    /// Plain text, truncated.
    var excerpt: String
}

/// Looks up the newest mail received from a person, across all accounts and
/// mailboxes of Apple Mail (AppleScript). Searching the sent mails by
/// recipient is far slower (measured 26-60 s) and not used. Escaping and
/// result parsing are pure and testable; the script itself needs a running
/// Mail. Any error, timeout or missing match yields no history.
enum MailHistoryService {
    static let minNameLength = 3
    static let maxExcerptCharacters = 4_000
    /// Overall budget from the start of the lookup until the caller gives up.
    static let budgetSeconds: Double = 18
    /// Upper bound for a single Apple event inside the script. The script
    /// deadline is the remaining budget minus this, so the last event of a
    /// late iteration still ends within the budget.
    static let eventTimeoutSeconds = 4
    /// Message bodies read per lookup, newest first. Dates are cheap, bodies
    /// are not.
    static let maxContentReads = 6

    // MARK: - Pure helpers

    /// The name to search for, or nil if it is too short to be a safe filter.
    static func searchName(from displayName: String) -> String? {
        let name = displayName
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return name.count >= minNameLength ? name : nil
    }

    /// The needle for the sender filter: the bare address of "Name <addr>"
    /// (more precise), else the cleaned display name.
    static func searchNeedle(from sender: String) -> String? {
        if let open = sender.lastIndex(of: "<"), let close = sender.lastIndex(of: ">"), open < close {
            let address = sender[sender.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if address.contains("@"), !address.contains(where: { $0.isWhitespace }) { return address }
        }
        return searchName(from: sender)
    }

    /// True if the sender is Ben himself; no history is looked up for him.
    static func isBen(_ sender: String) -> Bool {
        let lowered = sender.lowercased()
        if lowered.contains("scheffler") || lowered.contains("ben@parkourone.") { return true }
        let name = lowered.firstIndex(of: "<").map { String(lowered[..<$0]) } ?? lowered
        return name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) == "ben"
    }

    /// True if the greeting of the mail (first three non-empty lines, first
    /// 300 characters) addresses Ben: "Ben" as a word or "Scheffler". A mail
    /// to someone else ("Guten Morgen Christoph,") says nothing about the
    /// Du/Sie between Ben and the sender.
    static func addressesBen(_ content: String) -> Bool {
        let greeting = content.prefix(300)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "\n")
        return greeting.range(of: #"(?<![\p{L}\p{N}])Ben(?![\p{L}\p{N}])"#, options: .regularExpression) != nil
            || greeting.range(of: "Scheffler", options: .caseInsensitive) != nil
    }

    /// Escapes text for use inside an AppleScript string literal.
    static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Mailboxes whose name contains one of these are skipped: Ben's own sent
    /// mail and drafts never have the recipient as sender, trash and junk
    /// only cost time. A full scan of ~150 mailboxes took 7-10 s (measured
    /// 2026-10-29); the lookup starts at capture and runs during dictation.
    static let skippedMailboxWords = [
        "Gesendet", "Sent", "Entwürfe", "Drafts", "Papierkorb", "Trash", "Deleted",
        "Gelöscht", "Junk", "Werbung", "Spam",
    ]

    static var skipWordsLiteral: String {
        skippedMailboxWords.map { "\"\(escapeForAppleScript($0))\"" }.joined(separator: ", ")
    }

    /// One of the newest matching messages across all mailboxes.
    struct Candidate: Equatable {
        var date: Date
        var dateText: String
        var sender: String
        var content: String
    }

    /// The newest candidate by date received; nil for an empty list.
    static func newest(of candidates: [Candidate]) -> Candidate? {
        candidates.max { $0.date < $1.date }
    }

    /// The newest candidate whose greeting addresses Ben, else the newest.
    static func preferred(of candidates: [Candidate]) -> Candidate? {
        let newestFirst = candidates.sorted { $0.date > $1.date }
        return newestFirst.first { addressesBen($0.content) } ?? newestFirst.first
    }

    /// The lookup script. Mail evaluates `sender contains` itself, so only
    /// matching messages are touched. Pass 1 collects date and reference of
    /// every match in all non-skipped mailboxes (cheap); pass 2 reads the
    /// bodies of the `maxContentReads` newest and returns them (date, date
    /// text, sender, content truncated). Swift picks with `preferred(of:)`.
    /// All loops stop once `deadlineSeconds` have passed.
    static func script(
        forName name: String,
        deadlineSeconds: Int = 13,
        eventTimeoutSeconds: Int = MailHistoryService.eventTimeoutSeconds
    ) -> String {
        """
        with timeout of \(eventTimeoutSeconds) seconds
        tell application "Mail"
            set needle to "\(escapeForAppleScript(name))"
            set startTime to current date
            set expired to false
            set pool to {}
            set poolDates to {}
            set seenIds to {}
            set skipWords to {\(skipWordsLiteral)}
            repeat with a in accounts
                if expired then exit repeat
                set mbList to every mailbox of a
                set mbNames to name of every mailbox of a
                repeat with j from 1 to count of mbList
                    set mb to item j of mbList
                    if ((current date) - startTime) > \(deadlineSeconds) then
                        set expired to true
                        exit repeat
                    end if
                    set mbName to item j of mbNames
                    set skipBox to false
                    repeat with skipWord in skipWords
                        if mbName contains skipWord then set skipBox to true
                    end repeat
                    if not skipBox then
                        try
                            -- One whose-query per mailbox; dates are read per message because
                            -- `date received of <list>` fails, and `dates` is a reserved class name.
                            set found to (messages of mb whose sender contains needle)
                            repeat with i from 1 to count of found
                                if ((current date) - startTime) > \(deadlineSeconds) then
                                    set expired to true
                                    exit repeat
                                end if
                                set m to item i of found
                                -- The same mail often sits in several mailboxes (Gmail: inbox and All Mail).
                                set mid to ""
                                try
                                    set mid to message id of m
                                end try
                                if mid is "" or seenIds does not contain mid then
                                    if mid is not "" then set end of seenIds to mid
                                    set end of poolDates to date received of m
                                    set end of pool to m
                                end if
                            end repeat
                        end try
                    end if
                end repeat
            end repeat
            -- Newest first, bounded number of body reads.
            set results to {}
            repeat with k from 1 to \(maxContentReads)
                if ((current date) - startTime) > \(deadlineSeconds) then exit repeat
                set bestIdx to 0
                repeat with i from 1 to count of poolDates
                    set d to item i of poolDates
                    if d is not missing value then
                        if bestIdx is 0 then
                            set bestIdx to i
                        else if d > (item bestIdx of poolDates) then
                            set bestIdx to i
                        end if
                    end if
                end repeat
                if bestIdx is 0 then exit repeat
                try
                    set m to item bestIdx of pool
                    set bestDate to item bestIdx of poolDates
                    set c to content of m
                    if (length of c) > \(maxExcerptCharacters) then set c to text 1 thru \(maxExcerptCharacters) of c
                    set end of results to {bestDate, bestDate as string, sender of m, c}
                end try
                set item bestIdx of poolDates to missing value
            end repeat
            return results
        end tell
        end timeout
        """
    }

    /// Builds the history from the script's three result items; nil if the
    /// sender is missing or does not contain the searched name (guards
    /// against a wrong match), or the content is empty.
    static func parse(sender: String?, dateReceived: String?, content: String?, name: String) -> MailHistory? {
        guard let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty,
              sender.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        else { return nil }
        let excerpt = MailContextService.truncate(
            (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            limit: maxExcerptCharacters
        )
        guard !excerpt.isEmpty else { return nil }
        return MailHistory(
            sender: sender,
            dateReceived: (dateReceived ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            excerpt: excerpt
        )
    }

    // MARK: - Lookup (needs a running Mail)

    /// Runs the lookup on the shared AppleScript queue and returns after at
    /// most `budgetSeconds`. Never blocks the caller's thread; nil on any
    /// error, timeout or when nothing matches. The budget counts from this
    /// call: a job that only gets the queue after the caller gave up is
    /// skipped, and a late one gets a script deadline of what is left.
    /// `sender` is a display name (compose) or "Name <addr>" (reply); the
    /// address is searched when present.
    static func lookup(sender: String) async -> MailHistory? {
        guard !isBen(sender), let name = searchNeedle(from: sender) else { return nil }
        let enqueuedAt = Date()
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            MailContextService.scriptQueue.async {
                guard !once.isResumed else { return }
                let remaining = budgetSeconds - Date().timeIntervalSince(enqueuedAt)
                let deadline = Int(remaining) - eventTimeoutSeconds
                guard deadline >= 1 else {
                    once.resume(nil)
                    return
                }
                once.resume(run(name: name, deadlineSeconds: deadline))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + budgetSeconds) {
                if once.resume(nil) { mailHistoryLogger.notice("History lookup exceeded its budget") }
            }
        }
    }

    /// Executes on `MailContextService.scriptQueue` only.
    private static func run(name: String, deadlineSeconds: Int) -> MailHistory? {
        do {
            let descriptor = try MailContextService.executeScript(
                script(forName: name, deadlineSeconds: deadlineSeconds)
            )
            guard descriptor.descriptorType != typeNull, descriptor.numberOfItems >= 1 else { return nil }
            let candidates: [Candidate] = (1...descriptor.numberOfItems).compactMap { index in
                guard let item = descriptor.atIndex(index), item.numberOfItems >= 4,
                      let date = item.atIndex(1)?.dateValue,
                      let sender = item.atIndex(3)?.stringValue,
                      let content = item.atIndex(4)?.stringValue
                else { return nil }
                return Candidate(date: date, dateText: item.atIndex(2)?.stringValue ?? "", sender: sender, content: content)
            }
            guard let best = preferred(of: candidates) else { return nil }
            return parse(sender: best.sender, dateReceived: best.dateText, content: best.content, name: name)
        } catch {
            mailHistoryLogger.error("History lookup failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Resumes a continuation exactly once, whichever of result and timer
    /// comes first.
    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MailHistory?, Never>?

        init(_ continuation: CheckedContinuation<MailHistory?, Never>) {
            self.continuation = continuation
        }

        var isResumed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation == nil
        }

        /// - Returns: true if this call resumed the continuation.
        @discardableResult
        func resume(_ value: MailHistory?) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return pending != nil
        }
    }
}
