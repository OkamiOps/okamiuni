import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os retratos dos modais, nos três temas do desenho — e as medidas que eles
/// têm de bater.
///
/// Os três: `vidro` é o "claro" do protótipo, `vidroNoite` é o "escuro" e
/// `okami` é o "clássico" (os tokens dele são, literalmente, os que o
/// protótipo escreve em `classico` — `#0B0B12` de folha, `#323348` de aresta,
/// `#14141E` de campo, raio 2).
///
/// O que se afirma aqui é **medida**, não aparência: largura da folha, posição
/// do topo, a linha do rodapé, o raio. A aparência se confere no PNG, que sai
/// em `UNI_RENDER_DIR`.
@Suite("Retratos dos modais")
@MainActor
struct ModaisRenderTests {

    static let temas: [(String, Theme)] = [
        ("vidro", .vidro), ("vidro-noite", .vidroNoite), ("okami", .okami),
    ]

    private static let conta = Account(
        id: "conta", address: "vantion@aitherion.com", displayName: "Vantion",
        provider: .imap, host: "aitherion",
        tintLightHex: "#0ea5e9", tintDarkHex: "#38bdf8"
    )

    /// O dia do desenho: quatro compromissos entre 9h30 e 17h, com 15h livre.
    private static var agendaDoDesenho: [AgendaItem] {
        [
            AgendaItem(id: "a1", title: "Odette", startMinute: 570, endMinute: 600, accountID: "conta"),
            AgendaItem(id: "a2", title: "Aitherion Labs", startMinute: 600, endMinute: 720, accountID: "conta"),
            AgendaItem(id: "a3", title: "Almoço", startMinute: 720, endMinute: 780, accountID: "conta"),
            AgendaItem(id: "a4", title: "Call Marina", startMinute: 960, endMinute: 1020, accountID: "conta"),
        ]
    }

    static func store() async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [conta], messages: [], agenda: agendaDoDesenho
            )
        )
        await store.load()
        return store
    }

    // MARK: - Novo compromisso

    @Test("a folha de novo compromisso tem os 620 do desenho, nos três temas")
    func compromissoTem620() async throws {
        let store = await Self.store()
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                NewAppointmentSheet(
                    store: store, anchor: Fixtures.today, initialDayOffset: 0, onClose: {}
                ),
                named: "modal-compromisso-frase-\(nome)",
                size: NewAppointmentSheet.size, theme: tema
            ))
            #expect(rep.pixelsWide == Int(Theme.ModalWidth.appointment), "\(nome)")
            #expect(NewAppointmentSheet.width == 620)
        }
    }

    @Test("os campos abertos desenham as seis linhas, e mais do que a frase")
    func camposAbertos() async throws {
        let store = await Self.store()
        let frase = try #require(Render.bitmap(
            NewAppointmentSheet(
                store: store, anchor: Fixtures.today, initialDayOffset: 0, onClose: {}
            ),
            size: NewAppointmentSheet.size, theme: .vidro
        ))
        let campos = try #require(Render.snapshot(
            NewAppointmentSheet(
                store: store, anchor: Fixtures.today, initialDayOffset: 0,
                initialTitle: "Revisão da proposta · Aitherion", onClose: {}
            ),
            named: "modal-compromisso-pronto-vidro",
            size: NewAppointmentSheet.size, theme: .vidro
        ))
        // Seis linhas de campo, cada uma com a sua hairline: o estado aberto é
        // muito mais alto que o da frase, e é essa a diferença que se mede.
        #expect(campos.pixelsDiffering(from: frase) > 10_000)
    }

    @Test("a folha aberta no escuro e no clássico também")
    func camposNosOutrosTemas() async throws {
        let store = await Self.store()
        for (nome, tema) in [("vidro-noite", Theme.vidroNoite), ("okami", Theme.okami)] {
            #expect(Render.snapshot(
                NewAppointmentSheet(
                    store: store, anchor: Fixtures.today, initialDayOffset: 0,
                    initialTitle: "Revisão da proposta · Aitherion", onClose: {}
                ),
                named: "modal-compromisso-pronto-\(nome)",
                size: NewAppointmentSheet.size, theme: tema
            ) != nil, "\(nome)")
        }
    }

    // MARK: - A trilha de 8h–19h

    @Test("a trilha mede o dia de verdade, e diz que 15h está livre")
    func trilhaDoDia() async throws {
        let store = await Self.store()
        for (nome, tema) in Self.temas {
            #expect(Render.snapshot(
                DayFreeBusyStrip(
                    store: store, dayOffset: 0, day: Fixtures.today,
                    startMinute: 900, endMinute: 960
                )
                .padding(Theme.modalSide)
                .frame(width: Theme.ModalWidth.appointment)
                .background(tema.modalSheet.color),
                named: "modal-trilha-\(nome)",
                size: CGSize(width: Theme.ModalWidth.appointment, height: 110), theme: tema
            ) != nil, "\(nome)")
        }
    }

    // MARK: - A confirmação

    @Test("a confirmação tem os 420 do desenho, nos três temas")
    func confirmacaoTem420() throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                UNIConfirmation(
                    text: EmptyTrashConfirmation.text(count: 23, oldest: "março"),
                    onConfirm: {}, onCancel: {}
                ),
                named: "modal-confirmar-\(nome)",
                size: CGSize(width: Theme.ModalWidth.confirm, height: 180), theme: tema
            ))
            #expect(rep.pixelsWide == 420, "\(nome)")
        }
    }

    // MARK: - Contas

    @Test("adicionar conta: 500 de largura, Google e IMAP em teste")
    func adicionarConta() async throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                AddAccountForm(model: AccountsRehearsal.model(), initialAddress: "vantion@empresa.com.br")
                    .environment(\.theme, tema),
                named: "modal-conta-google-\(nome)",
                size: CGSize(width: Theme.ModalWidth.accountSheet, height: 520), theme: tema
            ))
            #expect(rep.pixelsWide == 500, "\(nome)")
        }
        #expect(Render.snapshot(
            AddAccountForm(
                model: AccountsRehearsal.model(),
                initialAddress: "financeiro@empresa.com.br",
                initialHost: "imap.empresa.com.br"
            ),
            named: "modal-conta-imap-vidro-noite",
            size: CGSize(width: Theme.ModalWidth.accountSheet, height: 620), theme: .vidroNoite
        ) != nil)
    }

    @Test("reconectar: 460 de largura, com o servidor numa linha mono")
    func reconectar() throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                ReconnectImapForm(
                    model: AccountsRehearsal.model(),
                    status: AccountsRehearsal.imapStatus,
                    onClose: {}
                ),
                named: "modal-reconectar-\(nome)",
                size: CGSize(width: Theme.ModalWidth.smallSheet, height: 420), theme: tema
            ))
            #expect(rep.pixelsWide == 460, "\(nome)")
        }
    }

    // MARK: - Sistema

    @Test("mover para Aplicativos: 460, centrada")
    func moverParaAplicativos() throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                MoveToApplicationsSheet(onMove: {}, onDismiss: {}),
                named: "modal-mover-\(nome)",
                size: CGSize(width: Theme.ModalWidth.smallSheet, height: 360), theme: tema
            ))
            #expect(rep.pixelsWide == 460, "\(nome)")
        }
    }

    @Test("o balão da atualização tem 380")
    func atualizacao() throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                UpdatePanel(controller: UpdateController.rehearsalReady),
                named: "modal-atualizacao-\(nome)",
                size: CGSize(width: Theme.ModalWidth.updatePopover, height: 330), theme: tema
            ))
            #expect(rep.pixelsWide == 380, "\(nome)")
            #expect(UpdatePanel.width == 380, "\(nome)")
        }
    }

    @Test("o seletor de tema tem 360 e separa vidros de clássicos")
    func temas() throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                ThemePickerPanel(onPick: { _ in }),
                named: "modal-temas-\(nome)",
                size: CGSize(width: Theme.ModalWidth.themePopover, height: 420), theme: tema
            ))
            #expect(rep.pixelsWide == 360, "\(nome)")
        }
    }

    @Test("o balão de mover para pasta tem 300")
    func pasta() throws {
        let grupos = [
            MoveFolderGroup(title: "Recentes", items: [
                ContextMenuItem(title: "Clientes / Aitherion", command: .noop),
                ContextMenuItem(title: "Financeiro", command: .noop),
            ]),
            MoveFolderGroup(title: "ricardo@empresa.com", items: [
                ContextMenuItem(title: "Arquivo", command: .noop),
                ContextMenuItem(title: "Clientes", command: .noop),
                ContextMenuItem(title: "Notas fiscais", command: .noop),
                ContextMenuItem(title: "Viagens", command: .noop),
            ]),
        ]
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                MoveFolderPanel(groups: grupos, onPick: { _ in }),
                named: "modal-pasta-\(nome)",
                size: CGSize(width: Theme.ModalWidth.folderPopover, height: 360), theme: tema
            ))
            #expect(rep.pixelsWide == 300, "\(nome)")
            #expect(MoveFolderPanel.width == 300, "\(nome)")
        }
    }
}
