import Foundation

// Pure Foundation, no other app dependencies: this file also compiles
// directly into the test target.

/// Form-of-address rule appended to the system prompt of every LLM
/// post-processing workflow. It is appended AFTER any custom prompt, because
/// custom prompts replace the defaults and would otherwise lose the rule.
enum AddressingRule {
    static let text = """
    Anredeform: Behalte die Anredeform exakt so bei, wie sie diktiert wurde. Wechsle nie von „du"/„ihr" zu „Sie" und führe „Sie" nicht ein, wo die sprechende Person es nicht selbst benutzt hat. Wird jemand angesprochen und das Diktat verrät keine Form, verwende „du" (eine KI wie Claude wird immer geduzt). „Sie" als Anrede gilt nur, wenn die sprechende Person es selbst verwendet („Sie", „siezen", „per Sie"). Das Pronomen „sie"/„Sie" im Sinn von „she"/„they" ist keine Anrede und bleibt unverändert. Ein formeller oder professioneller Ton bedeutet nicht „Sie".
    """

    /// Returns `prompt` with the rule appended as a separate paragraph.
    static func appended(to prompt: String) -> String {
        prompt + "\n\n" + text
    }
}
