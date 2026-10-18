@main
enum AlertLanguageCheck {
    static func main() {
        for language in ["de", "en", "nl", "lt", "et", "hr", "da", "fi", "sv", "nb", "fr", "it", "pl", "cs", "sk"] {
            precondition(AlertLanguage.code(for: language) == language, "\(language) is worded by the backend")
        }
        precondition(AlertLanguage.code(for: "de-AT") == "de")
        precondition(AlertLanguage.code(for: "nl_BE") == "nl")
        precondition(AlertLanguage.code(for: "DA") == "da")
        precondition(AlertLanguage.code(for: "no") == "nb", "Norwegian is sent as Bokmål")
        precondition(AlertLanguage.code(for: "nn-NO") == "nb", "Nynorsk readers get Bokmål, not English")
        precondition(AlertLanguage.code(for: "nb-NO") == "nb")
        precondition(AlertLanguage.code(for: "ru") == "en", "The backend rejects a language it has no words for")
        precondition(AlertLanguage.code(for: "Base") == "en")
        precondition(AlertLanguage.code(for: "") == "en")
        print("Alert language checks passed")
    }
}
