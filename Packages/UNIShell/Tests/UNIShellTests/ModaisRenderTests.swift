import AppKit
import Foundation
import NIOPosix
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// Os retratos dos modais, nos três temas do desenho — e as medidas que eles
/// têm de bater.
///
/// Os três: `vidro` é o "claro" do protótipo, `vidroNoite` é o "escuro" e
/// `okami` é o "clássico" (os tokens dele são, literalmente, os que o
/// protótipo escreve em `classico` — `#0B0B12` de folha, `#323348` de aresta,
/// `#14141E` de campo, raio 2).
///
/// O que se afirma aqui é **medida**: a largura de cada superfície, contra o
/// número do protótipo. A aparência se confere no PNG, que sai em
/// `UNI_RENDER_DIR`.
@Suite("Retratos dos modais", .serialized)
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

    // MARK: - A anatomia

    /// Os números do protótipo, nos três temas.
    ///
    /// Eles não se medem no PNG: um retrato em que a folha ocupa a largura do
    /// quadro não tem canto nenhum à vista, e o halo do acento é uma sombra,
    /// que não pinta pixel de cor sólida. O que se afirma é o token — que é o
    /// que o desenho escreve e o que toda superfície lê.
    @Test("raios e halo: 20/16/12 no Vidro, o raio do tema no clássico, halo só no Vidro")
    func anatomia() {
        for tema in [Theme.vidro, .vidroNoite] {
            #expect(tema.modalSheetRadius == 20, "\(tema.id)")
            #expect(tema.modalPopoverRadius == 16, "\(tema.id)")
            #expect(tema.modalFieldRadius == 12, "\(tema.id)")
            #expect(tema.modalButtonRadius == 10, "\(tema.id)")
            // `box-shadow: 0 6px 16px rgba(accent, 0.30)`.
            let halo = tema.modalAccentGlow
            #expect(halo.count == 1, "\(tema.id)")
            #expect(halo.first?.y == 6, "\(tema.id)")
            #expect(halo.first?.blur == 16, "\(tema.id)")
            #expect(halo.first?.color.opacity == 0.30, "\(tema.id)")
        }
        // Clássico: o raio é o do tema (2 no Okami) e o halo **não existe** —
        // o protótipo escreve `accentGlow: 'none'` nele.
        for tema in Theme.all where !tema.isTranslucent {
            #expect(tema.modalSheetRadius == tema.radiusLarge, "\(tema.id)")
            #expect(tema.modalPopoverRadius == tema.radiusLarge, "\(tema.id)")
            #expect(tema.modalFieldRadius == tema.radiusSmall, "\(tema.id)")
            #expect(tema.modalButtonRadius == tema.radiusSmall, "\(tema.id)")
            #expect(tema.modalAccentGlow.isEmpty, "\(tema.id)")
        }
        // E a folha é **opaca** nos 28: um modal é objeto elevado, e objeto
        // elevado não deixa o de baixo atravessar.
        for tema in Theme.all {
            #expect(tema.modalSheet.opacity == 1, "\(tema.id)")
        }
    }

    /// As medidas de posição e recuo que o desenho fixa.
    @Test("a folha pende de 56 do topo, e os recuos do cabeçalho e do rodapé")
    func medidas() {
        #expect(Theme.modalSheetTop == 56)
        #expect(Theme.modalHeaderTop == 26)
        #expect(Theme.modalSide == 28)
        #expect(Theme.modalFooterTop == 16)
        #expect(Theme.modalFooterBottom == 20)
        // `letter-spacing: -0.02em`, em pontos para o tamanho dado.
        #expect(Theme.vidro.modalTitleTracking(at: 24) == -0.48)
    }

    // MARK: - Novo compromisso

    @Test("a folha de novo compromisso tem os 620 do desenho, nos três temas")
    func compromissoTem620() async throws {
        let store = await Self.store()
        #expect(NewAppointmentSheet.width == 620)
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                NewAppointmentSheet(
                    store: store, anchor: Fixtures.today, initialDayOffset: 0,
                    // A frase do desenho, e o que ela produz: o cartão
                    // "Entendi assim" citando "amanhã" e "15h".
                    debugPhrase: "amanhã 15h com a Marina sobre a proposta",
                    onClose: {}
                ),
                named: "modal-compromisso-frase-\(nome)",
                size: NewAppointmentSheet.size, theme: tema
            ))
            #expect(rep.pixelsWide == Int(NewAppointmentSheet.size.width), "\(nome)")
        }
    }

    @Test("os campos abertos desenham muito mais que o estado da frase")
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
                size: CGSize(width: Theme.ModalWidth.confirm, height: 190), theme: tema
            ))
            #expect(rep.pixelsWide == 420, "\(nome)")
        }
    }

    @Test("a confirmação da janela do compromisso é a mesma peça")
    func confirmacaoDoCompromisso() throws {
        for kind in [EventConfirmKind.cancelMeeting, .removeFromCalendar] {
            let texto = kind.confirmationText
            #expect(texto.title == kind.title)
            #expect(texto.confirm == kind.actionTitle)
            #expect(Render.snapshot(
                UNIConfirmation(text: texto, onConfirm: {}, onCancel: {}),
                named: "modal-confirmar-\(kind == .cancelMeeting ? "reuniao" : "remover")-vidro",
                size: CGSize(width: Theme.ModalWidth.confirm, height: 190), theme: .vidro
            ) != nil)
        }
    }

    // MARK: - Contas

    @Test("adicionar conta: 500 de largura, no Google e no IMAP")
    func adicionarConta() async throws {
        let modelo = try await Self.accountsModel()
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                AddAccountForm(
                    model: modelo, initialAddress: "vantion@gmail.com", onClose: {}
                ),
                named: "modal-conta-google-\(nome)",
                size: CGSize(width: Theme.ModalWidth.accountSheet, height: 560), theme: tema
            ))
            #expect(rep.pixelsWide == 500, "\(nome)")
        }
        #expect(Render.snapshot(
            AddAccountForm(
                model: modelo,
                initialAddress: "financeiro@empresa.com.br",
                initialHost: "imap.empresa.com.br",
                onClose: {}
            ),
            named: "modal-conta-imap-vidro-noite",
            size: CGSize(width: Theme.ModalWidth.accountSheet, height: 700), theme: .vidroNoite
        ) != nil)
    }

    @Test("reconectar: 460 de largura, com o servidor numa linha mono")
    func reconectar() async throws {
        let modelo = try await Self.accountsModel()
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                ReconnectImapForm(
                    model: modelo, status: Self.imapStatus, onClose: {}
                ),
                named: "modal-reconectar-\(nome)",
                size: CGSize(width: Theme.ModalWidth.smallSheet, height: 430), theme: tema
            ))
            #expect(rep.pixelsWide == 460, "\(nome)")
        }
    }

    /// O estado "testando" do desenho (`Modal-conta-testando-escuro`), que o
    /// formulário inteiro não alcança sem rede: a trilha é fotografada
    /// sozinha, nos três estados que ela sabe desenhar.
    @Test("a trilha do teste IMAP, nos três temas e nos três estados")
    func trilhaDesenhada() throws {
        let estados: [(String, [ImapTestTrail.Step])] = [
            ("testando", ImapTestTrail.steps(running: true, passed: nil, error: nil)),
            ("passou", ImapTestTrail.steps(running: false, passed: true, error: nil)),
            ("falhou", ImapTestTrail.steps(running: false, passed: nil, error: .autenticacao)),
        ]
        for (nome, tema) in Self.temas {
            for (estado, passos) in estados {
                #expect(Render.snapshot(
                    ImapTestTrailView(steps: passos)
                        .padding(Theme.modalSide)
                        .frame(width: Theme.ModalWidth.accountSheet)
                        .background(tema.modalSheet.color),
                    named: "modal-conta-teste-\(estado)-\(nome)",
                    size: CGSize(width: Theme.ModalWidth.accountSheet, height: 170), theme: tema
                ) != nil, "\(nome)/\(estado)")
            }
        }
    }

    /// A trilha do teste IMAP conta o que **o resultado permite** contar: a
    /// classe do erro diz onde parou. Ver `ImapTestTrail`.
    @Test("a trilha do teste para no passo que o erro nomeia")
    func trilhaDoTeste() {
        #expect(ImapTestTrail.failureIndex(.rede("sem rota")) == 0)
        #expect(ImapTestTrail.failureIndex(.tls("certificado")) == 1)
        #expect(ImapTestTrail.failureIndex(.autenticacao) == 2)

        let parado = ImapTestTrail.steps(running: false, passed: nil, error: .autenticacao)
        #expect(parado.map(\.state) == [.done, .done, .now, .waiting])
        #expect(parado.filter(\.failed).count == 1)
        #expect(parado[2].failed)

        let passou = ImapTestTrail.steps(running: false, passed: true, error: nil)
        #expect(passou.allSatisfy { $0.state == .done })
        #expect(passou.allSatisfy { !$0.failed })

        let rodando = ImapTestTrail.steps(running: true, passed: nil, error: nil)
        #expect(rodando.first?.state == .now)
        #expect(rodando.dropFirst().allSatisfy { $0.state == .waiting })
    }

    // MARK: - Sistema

    @Test("mover para Aplicativos: 460, centrada")
    func moverParaAplicativos() throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                MoveToApplicationsSheet(onMove: {}, onDismiss: {}),
                named: "modal-mover-\(nome)",
                size: CGSize(width: Theme.ModalWidth.smallSheet, height: 330), theme: tema
            ))
            #expect(rep.pixelsWide == 460, "\(nome)")
        }
    }

    @Test("o balão da atualização tem 380")
    func atualizacao() throws {
        #expect(UpdatePanel.width == 380)
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                UpdatePanel(controller: try Self.atualizadorPronto(nome)),
                named: "modal-atualizacao-\(nome)",
                size: CGSize(width: Theme.ModalWidth.updatePopover, height: 340), theme: tema
            ))
            #expect(rep.pixelsWide == 380, "\(nome)")
        }
    }

    @Test("o seletor de tema tem 360 e separa vidros de clássicos")
    func temas() throws {
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                ThemePickerPanel(onPick: { _ in }),
                named: "modal-temas-\(nome)",
                size: CGSize(width: Theme.ModalWidth.themePopover, height: 400), theme: tema
            ))
            #expect(rep.pixelsWide == 360, "\(nome)")
        }
    }

    @Test("o balão de mover para pasta tem 300")
    func pasta() throws {
        #expect(MoveFolderPanel.width == 300)
        let grupos = [
            MoveFolderGroup(title: "Recentes", items: [
                ContextMenuItem("Clientes / Aitherion", .copy("c")),
                ContextMenuItem("Financeiro", .copy("f")),
            ]),
            MoveFolderGroup(title: "ricardo@empresa.com", items: [
                ContextMenuItem("Arquivo", .copy("a")),
                ContextMenuItem("Clientes", .copy("cl")),
                ContextMenuItem("Notas fiscais", .copy("n")),
                ContextMenuItem("Viagens", .copy("v")),
            ]),
        ]
        for (nome, tema) in Self.temas {
            let rep = try #require(Render.snapshot(
                MoveFolderPanel(groups: grupos, onPick: { _ in }),
                named: "modal-pasta-\(nome)",
                size: CGSize(width: Theme.ModalWidth.folderPopover, height: 380), theme: tema
            ))
            #expect(rep.pixelsWide == 300, "\(nome)")
        }
    }

    @Test("a faixa de desfazer traz a barra de tempo e o atalho")
    func desfazer() throws {
        let mensagem = Self.mensagem(
            id: "m-undo",
            from: Contact(name: "Nubank", address: "nubank@nubank.com.br"),
            subject: "Fatura de setembro"
        )
        let recibo = try #require(SwipeReceipt.of(.archive, message: mensagem, stamp: "14:32"))
        for (nome, tema) in Self.temas {
            #expect(Render.snapshot(
                SwipeUndoBand(receipt: recibo, onUndo: {})
                    .padding(20),
                named: "modal-desfazer-\(nome)",
                size: CGSize(width: 520, height: 100), theme: tema
            ) != nil, "\(nome)")
        }
        #expect(SwipeUndoBand.lifetimeSeconds == 6)
    }

    // MARK: - Janelas próprias

    @Test("a janela do compromisso tem 640, e a da mensagem 880×720")
    func janelas() {
        #expect(UNIWindow.Size.event.width == 640)
        #expect(UNIWindow.Size.message == CGSize(width: 880, height: 720))
    }

    @Test("a contagem só aparece perto da hora")
    func contagem() {
        let agora = Fixtures.today
        let em12 = agora.addingTimeInterval(12 * 60)
        #expect(EventPrep.countdown(start: em12, end: em12.addingTimeInterval(3600), now: agora) == "12 min")
        let em3h = agora.addingTimeInterval(3 * 3600)
        #expect(EventPrep.countdown(start: em3h, end: em3h.addingTimeInterval(3600), now: agora) == nil)
        // Em curso: há contagem, e ela é a palavra de "agora" no idioma
        // corrente — comparar com o literal "agora" torna o caso dependente
        // de qual catálogo o processo de teste resolveu.
        let comecou = agora.addingTimeInterval(-10 * 60)
        #expect(
            EventPrep.countdown(start: comecou, end: agora.addingTimeInterval(600), now: agora)
                == L10n.tr("agora")
        )
        let acabou = agora.addingTimeInterval(-7200)
        #expect(EventPrep.countdown(start: acabou, end: agora.addingTimeInterval(-3600), now: agora) == nil)
    }

    /// Sem e-mail destas pessoas, o bloco de preparo **não existe** — em vez de
    /// aparecer vazio ou com texto inventado.
    @Test("o preparo sai do MailStore, e sem dado não aparece")
    func preparo() {
        let marina = EventPerson(
            name: "Marina Costa", address: "marina@aitherion.com",
            role: "participante", status: .yes
        )
        #expect(EventPrep.lines(guests: [marina], messages: [], me: "eu@x.com").isEmpty)

        let mensagem = Self.mensagem(
            id: "m1",
            from: Contact(name: "Marina Costa", address: "marina@aitherion.com"),
            subject: "Proposta revisada — fase 2"
        )
        let linhas = EventPrep.lines(guests: [marina], messages: [mensagem], me: "eu@x.com")
        #expect(linhas.count == 1)
        #expect(linhas.first?.what == "Proposta revisada — fase 2")
        #expect(linhas.first?.id == "m1")
    }

    // MARK: - Andaimes

    /// Uma mensagem com os campos que estes retratos usam, sobre a fixture —
    /// o `Message` tem uma dúzia de campos e nenhum deles muda o que se mede
    /// aqui.
    private static func mensagem(id: String, from: Contact, subject: String) -> Message {
        let base = Fixtures.messages[0]
        return Message(
            id: id, accountID: "conta", from: from,
            receivedAt: Fixtures.today, subject: subject, snippet: base.snippet,
            body: base.body, tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil
        )
    }

    private static var imapStatus: AccountStatus {
        AccountStatus(
            accountID: "conta", address: "vantion@empresa.com.br", hostMark: "empresa",
            state: .erroDeAutenticacao, messageCount: 1_240,
            lastSyncedAt: Fixtures.today,
            error: .autenticacao, progress: nil,
            provider: .imap,
            imap: ImapEndpoint(host: "imap.empresa.com.br", port: 993, security: .tls)
        )
    }

    private static func accountsModel() async throws -> AccountsModel {
        let database = try SyncDatabase.temporary()
        let director = AccountDirector(
            database: database,
            secrets: InMemorySecretStore(),
            auth: nil,
            session: .shared,
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            imapConnect: { _, _ in throw SyncError.rede("o retrato não abre conexão") }
        )
        return AccountsModel(director: director)
    }

    private static func atualizadorPronto(_ nome: String) throws -> UpdateController {
        let suite = "render-modais-\(nome)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let motor = MotorDeMentira()
        let controller = UpdateController(engine: motor, defaults: defaults)
        motor.emite(.ready(UpdateRelease(
            version: "2.5",
            changelog: UpdateChangelog(
                portuguese: [
                    "Modais e janelas redesenhados, com o Vidro inteiro",
                    "Temas clássicos: 28 opções opacas, sem desfoque",
                    "A coluna recolhida volta pelo trilho",
                ],
                english: []
            ),
            releaseURL: URL(string: "https://github.com/okamiops/okamiuni/releases/tag/v2.5")
        )))
        return controller
    }
}
