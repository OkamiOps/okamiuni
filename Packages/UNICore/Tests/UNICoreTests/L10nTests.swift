import Foundation
import Testing
@testable import UNICore

@Suite("L10n")
struct L10nTests {

    @Test("interpolação cria chave estável e preserva os valores")
    func interpolationBuildsNumberedPlaceholders() {
        let message: LocalizedString = "Olá, \("Ada") — você tem \(3) mensagens."

        #expect(message.key == "Olá, {0} — você tem {1} mensagens.")
        #expect(message.values.count == 2)
        #expect(message.values[0] as? String == "Ada")
        #expect(message.values[1] as? Int == 3)
    }

    @Test("texto localizado pode reordenar argumentos")
    func explicitLanguageFormatsItsArguments() {
        let rendered = L10n.tr("{1} depois de \("primeiro") e \("segundo")", language: .german)

        #expect(rendered == "segundo depois de primeiro e segundo")
    }

    @Test("um valor não dispara nova substituição")
    func interpolationDoesNotRecurse() {
        let rendered = L10n.tr("\("{1}") / \("fim")", language: .french)

        #expect(rendered == "{1} / fim")
    }

    @Test("os idiomas têm identificadores de persistência estáveis")
    func appLanguagePersistenceValues() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "pt-BR", "en", "de", "fr"])
        #expect(AppLanguage.german.nativeName == "Deutsch")
        #expect(AppLanguage.french.locale.identifier == "fr")
    }

    @Test("reconhece promessas de desfazer em todos os idiomas suportados")
    func undoRecognitionIsIndependentFromDisplayLanguage() {
        for suffix in [
            "Dá para desfazer.",
            "You can undo this.",
            "Du kannst das rückgängig machen.",
            "Vous pouvez annuler cette action.",
        ] {
            let parsed = AssistantProposalCard.stripUndoPromise("Arquivar tudo. \(suffix)")
            #expect(parsed.text == "Arquivar tudo.")
            #expect(parsed.claimed)
        }
    }

    @Test("formata data sem gramática fixa em português")
    func dateLabelsUseTheRequestedLocale() {
        let date = Date(timeIntervalSince1970: 1_661_385_600) // 25/08/2022 12:00 UTC
        let english = DateLabels.eventDate(date, locale: Locale(identifier: "en_US"))

        #expect(!english.localizedCaseInsensitiveContains(" de "))
    }

    @Test("reserva de título respeita a ordem de data do idioma")
    func calendarTitleReserveUsesRequestedLocale() {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25))!

        for locale in ["pt_BR", "en_US", "de_DE", "fr_FR"].map(Locale.init(identifier:)) {
            let pieces = CalendarTitleReserve.longDayTitlePieces(
                inYearOf: anchor,
                calendar: calendar,
                locale: locale
            )
            let possibleTitles = Set(pieces.prefixes.flatMap { prefix in
                pieces.suffixes.map { prefix + $0 }
            })

            for offset in 0..<365 {
                let title = MonthAgenda.longDayTitle(
                    dayOffset: offset,
                    anchor: anchor,
                    calendar: calendar,
                    locale: locale
                )
                #expect(possibleTitles.contains(replacingDayWithWorstCase(title)))
            }
        }
    }

    @Test("plural do rascunho recebe idioma explícito")
    func draftWordCountUsesExplicitLanguage() {
        #expect(DraftMeta.countLabel("one two", language: .english) == "2 words")
    }

    private func replacingDayWithWorstCase(_ text: String) -> String {
        var result = ""
        var replaced = false
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isNumber {
                var end = index
                while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
                result += replaced ? String(text[index..<end]) : "30"
                replaced = true
                index = end
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }
}

@Suite("Bundled translations")
struct BundledTranslationTests {
    @Test("catalog lookup uses the requested language", arguments: [
        (AppLanguage.portugueseBrazil, "Cancelar"),
        (.english, "Cancel"), (.german, "Abbrechen"), (.french, "Annuler")
    ])
    func translatedAction(_ language: AppLanguage, _ expected: String) {
        #expect(L10n.tr("Cancelar", language: language) == expected)
    }

    @Test("translated interpolation retains user content", arguments: [
        (AppLanguage.english, "Folder or label for R&D {1}"),
        (.german, "Ordner oder Label für R&D {1}"),
        (.french, "Dossier ou libellé de R&D {1}")
    ])
    func translatedInterpolation(_ language: AppLanguage, _ expected: String) {
        #expect(L10n.tr("Pasta ou marcador de \("R&D {1}")", language: language) == expected)
    }
}
