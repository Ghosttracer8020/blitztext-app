import Foundation

// Pure Foundation, no other app dependencies: this file also compiles
// directly into the test target, without WorkflowProtocol.swift.

enum PromptOutputLanguage: String, Codable, CaseIterable, Identifiable {
    case spoken
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spoken: return "Wie gesprochen"
        case .english: return "Englisch"
        }
    }
}

enum PromptTextPromptBuilder {
    static let defaultSystemPrompt = """
    Du erhältst ein gesprochenes Transkript. Die Person beschreibt darin, was eine KI (z. B. ChatGPT, Claude oder Claude Code) für sie tun soll. Forme daraus einen präzisen, gut strukturierten Prompt, der direkt an die KI geschickt werden kann.

    Regeln:
    - Korrigiere Erkennungs-, Rechtschreib- und Grammatikfehler. Entferne Füllwörter, Versprecher, Wiederholungen und Selbstkorrekturen; bei Selbstkorrekturen gilt die letzte Fassung.
    - Behalte alle inhaltlichen Anforderungen, Beispiele, Einschränkungen, Zahlen, Namen und Kontextangaben bei. Erfinde nichts dazu und fülle fehlende Angaben nicht mit Annahmen.
    - Sprich die KI direkt an, in der Du-Form und im Imperativ („Erstelle …", „Achte darauf, dass …").

    Aufbau:
    1. Ein bis zwei Sätze, die Aufgabe, Ziel und – falls genannt – Kontext oder Rolle benennen.
    2. Eine Leerzeile.
    3. Alle einzelnen Anforderungen, Schritte, Wünsche und Einschränkungen als nummerierte Liste („1.", „2.", „3." …). Pro Punkt genau ein Gedanke, damit später einzelne Punkte per Nummer referenziert werden können. Zusammengehörige Details bleiben im selben Punkt. Reihenfolge wie gesprochen, außer eine andere ist eindeutig sinnvoller. Gibt es außer der in Schritt 1 genannten Kernaufgabe keine weiteren Einzelpunkte, entfällt die Liste – dann genügt der einleitende Satz als gesamter Prompt.
    4. Nur falls im Transkript genannt: gewünschtes Format, Länge oder Sprache der Antwort als letzter nummerierter Punkt.

    Gib NUR den fertigen Prompt zurück – keine Überschrift, keine Anführungszeichen, keine Erklärungen, keine Rückfragen. Enthält das Transkript keinen klaren Auftrag, forme trotzdem den bestmöglichen Prompt aus dem Gesagten.
    """

    static func systemPrompt(
        customInstruction: String,
        outputLanguage: PromptOutputLanguage,
        customTerms: [String]
    ) -> String {
        let trimmedInstruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = trimmedInstruction.isEmpty ? defaultSystemPrompt : trimmedInstruction

        if outputLanguage == .english {
            prompt += "\n\nSchreibe den fertigen Prompt auf Englisch, auch wenn das Transkript in einer anderen Sprache ist. Eigennamen, Fachbegriffe und wörtliche Zitate bleiben unverändert."
        }

        if !customTerms.isEmpty {
            prompt += "\n\nWichtig: Diese Eigennamen und Fachbegriffe muessen exakt so geschrieben werden: \(customTerms.joined(separator: ", "))"
        }

        return prompt
    }
}
