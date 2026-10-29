import Foundation
import os

private let mailHistoryLogger = Logger(subsystem: "app.blitztext.mac", category: "MailHistory")

/// The newest mail Ben received from the recipient of a new mail. Used only
/// to decide Du/Sie and to get names right.
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

    // MARK: - Pure helpers

    /// The name to search for, or nil if it is too short to be a safe filter.
    static func searchName(from displayName: String) -> String? {
        let name = displayName
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return name.count >= minNameLength ? name : nil
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

    /// One match per mailbox: the newest message of that mailbox.
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

    /// The lookup script. Mail evaluates `sender contains` itself, so only
    /// matching messages cross the process boundary. It returns the newest
    /// match of every mailbox that has one (date, date text, sender, content
    /// truncated); Swift picks the overall newest (`newest(of:)`). The loops
    /// stop once `deadlineSeconds` have passed, in both the mailbox and the
    /// account loop.
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
            set results to {}
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
                            set n to count of found
                            if n > 0 then
                                set m to item 1 of found
                                set bestDate to date received of m
                                repeat with i from 2 to n
                                    set dr to date received of (item i of found)
                                    if dr > bestDate then
                                        set bestDate to dr
                                        set m to item i of found
                                    end if
                                end repeat
                                set c to content of m
                                if (length of c) > \(maxExcerptCharacters) then set c to text 1 thru \(maxExcerptCharacters) of c
                                set end of results to {bestDate, bestDate as string, sender of m, c}
                            end if
                        end try
                    end if
                end repeat
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
    static func lookup(displayName: String) async -> MailHistory? {
        guard let name = searchName(from: displayName) else { return nil }
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
            guard let best = newest(of: candidates) else { return nil }
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
