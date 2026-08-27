import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A metade do menu de contexto que **não** cabe em `UNICore`: a que precisa do
/// `MailStore` e do calendário do dispositivo para montar as entradas de um
/// compromisso.
///
/// O `NSMenu` em si não entra aqui. O SwiftUI só o constrói quando um clique
/// com o botão direito chega, e sintetizar esse clique tomaria a máquina de
/// quem está trabalhando — a regra do projeto. O que dá para provar, e é o que
/// importa, é a lista de itens que aquele clique vai receber.
@Suite("Menu de contexto nas superfícies")
@MainActor
struct ContextMenuSurfaceTests {

    private func loadedStore() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("o cartão de compromisso monta o menu com o detalhe e a origem certos")
    func agendaMenuIsAssembled() async throws {
        let store = await loadedStore()
        // O 1:1 com a Marina: tem link de reunião e tem linha de email no
        // histórico, então o menu dele é o completo.
        let item = try #require(store.agenda.first { $0.title.hasPrefix("1:1") })

        let entries = AgendaContextMenu.entries(
            for: item, store: store, anchor: Fixtures.today
        )

        #expect(entries.titles == [
            "Abrir detalhe",
            "Copiar link da reunião",
            "Copiar convite",
            "Ir para o email de origem",
        ])
        #expect(entries.commands.contains(.openEvent(itemID: item.id)))
        // A origem sai do histórico do compromisso, casada com o assunto.
        #expect(entries.commands.contains(.revealMessage(messageID: "m1")))
    }

    @Test("compromisso sem link nem histórico fica com o menu curto")
    func agendaMenuShrinks() async throws {
        let store = await loadedStore()
        // "Revisão semanal" não tem link e tem histórico vazio.
        let item = try #require(store.agenda.first { $0.title == "Revisão semanal" })

        let entries = AgendaContextMenu.entries(
            for: item, store: store, anchor: Fixtures.today
        )

        #expect(entries.titles == ["Abrir detalhe", "Copiar convite"])
        // E o menu curto continua bem formado: nada de traço solto no fim.
        #expect(entries.last?.isSeparator != true)
    }

    /// `dayOffset` é deslocamento em dias inteiros justamente para não
    /// atravessar fuso. Somá-lo à âncora é a única conversão, e ela tem de
    /// cair no dia certo — senão o convite copiado marca o dia errado.
    @Test("o convite copiado leva o dia do compromisso, não o da âncora")
    func inviteCarriesTheRightDay() async throws {
        let store = await loadedStore()
        let later = try #require(store.agenda.first { $0.dayOffset > 0 })
        let expected = try #require(
            Calendar.current.date(byAdding: .day, value: later.dayOffset, to: Fixtures.today)
        )

        let entries = AgendaContextMenu.entries(
            for: later, store: store, anchor: Fixtures.today
        )
        let invite = try #require(entries.commands.compactMap { command -> String? in
            if case .copy(let text) = command, text.contains(later.title) { return text }
            return nil
        }.first)

        #expect(invite.contains(DateLabels.eventDate(expected)))
        #expect(!invite.contains(DateLabels.eventDate(Fixtures.today)))
        #expect(invite.contains(later.rangeLabel))
    }

    /// Menu de contexto muda hit testing e pode mudar desenho. As suítes de
    /// pixel deste pacote já cobrem cada painel; esta é a rede embaixo delas:
    /// as quatro superfícies que ganharam menu continuam desenhando conteúdo.
    @Test("as superfícies com menu continuam desenhando")
    func surfacesStillDraw() async throws {
        let store = await loadedStore()
        let theme = ThemeStore().theme

        let surfaces: [(String, AnyView, CGSize)] = [
            ("lista", AnyView(MessageList(store: store)), CGSize(width: 370, height: 600)),
            ("leitor", AnyView(ReaderPane(store: store)),
             CGSize(width: 560, height: 600)),
            ("lateral", AnyView(FolderSidebar(store: store)), CGSize(width: 236, height: 600)),
            ("trilha", AnyView(
                AgendaRail(store: store, now: Fixtures.nowMinute, headerDate: Fixtures.today)
            ), CGSize(width: 240, height: 600)),
        ]

        for (name, view, size) in surfaces {
            let bitmap = try #require(
                Render.snapshot(view, named: "menu-\(name)", size: size, theme: theme),
                "\(name) não renderizou"
            )
            // Painel em branco desenha uma cor só. Contar cores distintas pega
            // o caso em que o menu engoliu o conteúdo — que é o modo de falhar
            // que importa aqui.
            #expect(distinctColors(in: bitmap) > 8, "\(name) saiu praticamente vazio")
        }
    }

    private func distinctColors(in bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let step = 3
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let r = UInt32(color.redComponent * 255)
                let g = UInt32(color.greenComponent * 255)
                let b = UInt32(color.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
                if seen.count > 64 { return seen.count }
            }
        }
        return seen.count
    }
}
