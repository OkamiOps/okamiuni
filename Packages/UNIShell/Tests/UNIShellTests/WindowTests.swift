import Testing
import SwiftUI
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Janelas")
struct WindowTests {

    /// Trava os tamanhos escritos no protótipo. Cada número vem de uma linha
    /// citada no brief; se alguém "arredondar" um deles, isto acusa.
    @Test("os tamanhos são os do protótipo")
    func sizes() {
        #expect(UNIWindow.Size.composer == CGSize(width: 820, height: 660))    // 03, linha 790
        #expect(UNIWindow.Size.newMessage == CGSize(width: 820, height: 620))  // 06, linha 368
        #expect(UNIWindow.Size.message == CGSize(width: 800, height: 600))     // 05, linha 745
        #expect(UNIWindow.Size.event.width == 560)                             // 04, linha 590
    }

    @Test("cada janela tem seu identificador de cena")
    func distinctSceneIDs() {
        let ids = [UNIWindow.composer, UNIWindow.newMessage, UNIWindow.message, UNIWindow.event]
        #expect(Set(ids).count == ids.count)
    }

    @Test("o título da barra distingue responder de escrever do zero")
    @MainActor
    func composerTitle() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })

        #expect(ComposerWindow.windowTitle(replyingTo: message)
                == "Re: Revisão do contrato — podemos fechar quinta?")
        // 06 não responde a ninguém.
        #expect(ComposerWindow.windowTitle(replyingTo: nil) == "Nova mensagem")
    }

    @Test("responder a uma mensagem que sumiu não vira 'Re: '")
    func composerTitleWithoutSubject() {
        let ghost = Message(
            id: "x", accountID: "zoho",
            from: Contact(name: "", address: ""), receivedAt: .now,
            subject: "", snippet: "", body: [], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
        #expect(ComposerWindow.windowTitle(replyingTo: ghost) == "Nova mensagem")
    }

    @Test("a linha do organizador separa nome e endereço por cor")
    func organizerLine() {
        let line = EventWindow.organizerLine(
            name: "Marina Duarte", address: "marina@clientepremium.com",
            ink: .black, ink3: .gray
        )
        #expect(String(line.characters) == "Marina Duarte · marina@clientepremium.com")

        let colors = line.runs.map(\.foregroundColor)
        #expect(colors == [.black, .gray])
    }

    /// A trilha de agenda é o gatilho da janela 04: o compromisso clicado tem de
    /// levar consigo um detalhe que a tela sabe desenhar.
    @Test("cada compromisso da trilha resolve um detalhe para a janela 04")
    @MainActor
    func everyRailItemHasDetail() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(!store.agenda.isEmpty)

        for item in store.agenda {
            let detail = Fixtures.eventDetail(for: item.title)
            // O organizador é o único campo que a tela nunca pode não ter:
            // o roster começa nele.
            #expect(!detail.organizer.name.isEmpty)
            #expect(detail.guestCount >= 1)
        }

        // E o que o protótipo de fato descreve chega inteiro:
        let oneOnOne = try #require(store.agenda.first { $0.id == "e2" })
        let detail = Fixtures.eventDetail(for: oneOnOne.title)
        #expect(detail.hasLink)
        #expect(detail.agenda.count == 3)
        #expect(oneOnOne.rangeLabel == "11:00 – 11:45")
    }
}

/// O rodapé da janela 04 — os dois botões que eram mudos.
///
/// "Email" tinha `ChromeButton(...) {}`: ação vazia, habilitado, sem `help`.
/// "Reagendar" idem, e sem tela de edição de agenda para onde levar — foi
/// **removido**; volta no Marco 4, com o EventKit.
@Suite("Janela 04 — rodapé")
@MainActor
struct EventWindowFooterTests {

    private func loaded() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    /// O botão leva ao mesmo lugar que "Ir para o email de origem" dos menus,
    /// e pela mesma regra: `ContextMenus.originMessageID`.
    @Test("«Email» aponta para a mesma mensagem que o item do menu de contexto")
    func emailButtonTargetsTheOriginMessage() async throws {
        let store = await loaded()
        let item = try #require(store.agenda.first { $0.id == "e2" })
        let detail = Fixtures.eventDetail(for: item.title)
        let expected = try #require(ContextMenus.originMessageID(for: detail, in: store.messages))

        let window = EventWindow(store: store, itemID: "e2")
        #expect(window.originMessageID == expected)
    }

    /// E ele **age**: revela a mensagem na janela principal, custe o que custar
    /// em filtros — é o que `MailStore.reveal` faz, e é o que a ação vazia não
    /// fazia. O cenário é o pior: outra conta filtrada, outra caixa aberta e
    /// uma busca que não casa.
    @Test("«Email» revela a mensagem de origem, desfazendo o que a escondia")
    func emailButtonRevealsTheMessage() async throws {
        let store = await loaded()
        let window = EventWindow(store: store, itemID: "e2")
        let target = try #require(window.originMessageID)
        let message = try #require(store.messages.first { $0.id == target })

        let other = try #require(store.accounts.first { $0.id != message.accountID })
        store.select(account: other.id)
        store.select(bucket: message.bucket == .today ? .later : .today)
        store.query = "zzz-nao-casa-com-nada"
        let before = store.revealCount
        #expect(store.selectedMessageID != target)

        window.revealOriginMessage()

        #expect(store.selectedMessageID == target)
        #expect(store.selectedAccountID == nil)
        #expect(store.bucket.contains(message))
        #expect(store.query.isEmpty)
        // E a janela principal fica sabendo: é por este contador que ela volta
        // para a aba Email, que é `@State` de outra cena.
        #expect(store.revealCount == before + 1)
    }

    /// **A janela mostra o que o compromisso carrega.** As duas telas são o
    /// mesmo compromisso, no mesmo horário, com o mesmo título: o que muda é
    /// um trazer o detalhe do convite (sala de verdade, link, o Favini
    /// organizando, a descrição) e o outro não. Uma janela que preenchesse com
    /// `Fixtures.eventDetail` — o estado de antes deste conserto — desenharia
    /// as duas idênticas, com "Sem local definido" e "Ricardo Gomes" nas duas.
    @Test("O compromisso vindo de convite desenha o que veio, não a fixture")
    func oDetalheDoConviteAparece() async throws {
        func janela(_ detail: EventDetail?) async -> NSBitmapImageRep? {
            let item = AgendaItem(
                id: "email-m1", title: "DreamSquad",
                startMinute: 594, endMinute: 644, accountID: "zoho",
                dayOffset: 0, calendarUID: "u1", calendarSequence: 0, detail: detail
            )
            let store = MailStore(
                source: InMemoryMailSource(
                    accounts: Fixtures.accounts, messages: [], agenda: [item]
                )
            )
            await store.load()
            return Render.bitmap(
                EventWindow(store: store, itemID: "email-m1"),
                size: CGSize(width: 560, height: 700), theme: .tinta
            )
        }

        let doConvite = EventDetail(
            place: "Sala Vantion, 4º andar",
            link: "https://meet.google.com/abc-defg-hij",
            organizer: EventPerson(
                name: "Favini", address: "favini@vantion.com.br",
                role: "organizador", status: .yes
            ),
            people: [
                EventPerson(
                    name: "Marcos Santos", address: "marcos@vantion.com.br",
                    role: "convidado", status: .pending
                )
            ],
            note: "Do convite por email · conta vantion",
            recurrence: "Evento único", notice: "Sem alerta",
            agenda: [], thread: [],
            descricao: "Pauta do time."
        )
        let comDetalhe = try #require(await janela(doConvite))
        let semDetalhe = try #require(await janela(nil))
        #expect(
            comDetalhe.pixelsDiffering(from: semDetalhe) > 0,
            "a janela desenhou a fixture no lugar do que o convite trouxe"
        )
    }

    @Test("o que eu criei cancela; o resto remove do calendário")
    func createdHereCancelsTheRestRemoves() {
        #expect(EventWindow.isCreatedHere("manual-abc"))
        #expect(!EventWindow.isCreatedHere("e2"))
        #expect(!EventWindow.isCreatedHere("email-m1"))
    }

    @Test("o aviso de remover é o cartão do app, não o diálogo do sistema")
    func customRemoveNotice() async throws {
        #expect(EventConfirmKind.removeFromCalendar.title == "Remover do calendário?")
        #expect(EventConfirmKind.cancelMeeting.actionTitle == "Cancelar reunião")

        let store = await Self.loja(Self.detalheDeConvite(link: "https://meet.google.com/abc"))
        let rep = try #require(
            Render.snapshot(
                EventWindow(
                    store: store, itemID: "email-m1",
                    debugConfirm: .removeFromCalendar
                ).environment(ThemeStore()),
                named: "evento-04-aviso-remover",
                size: CGSize(width: 560, height: 700),
                theme: .tinta
            )
        )
        // Magenta no miolo da janela: o cartão. O botão do rodapé mora em y=660.
        #expect(Self.hasRemoveFill(in: rep, yRange: 250...450, width: 560))
    }

    @Test("sair do compositor pergunta se grava o rascunho")
    func composerLeaveCopy() {
        #expect(ComposerLeaveConfirm.title == "Salvar no rascunho?")
        #expect(ComposerLeaveConfirm.saveTitle == "Salvar")
        #expect(ComposerLeaveConfirm.discardTitle == "Não salvar")
        #expect(ComposerLeaveConfirm.cancelTitle == "Cancelar")
        #expect(ComposerLeaveConfirm.shouldPrompt(isDirty: true))
        #expect(!ComposerLeaveConfirm.shouldPrompt(isDirty: false))
    }

    @Test("o aviso de sair do compositor é o cartão do app")
    func composerLeaveNotice() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let original = try #require(store.messages.first)
        let comAviso = try #require(
            Render.snapshot(
                ComposerWindow(
                    store: store, mode: .reply(messageID: original.id),
                    debugLeaveConfirm: true
                ).environment(ThemeStore()),
                named: "composer-aviso-salvar",
                size: CGSize(width: 820, height: 660),
                theme: .tinta
            )
        )
        let semAviso = try #require(
            Render.snapshot(
                ComposerWindow(
                    store: store, mode: .reply(messageID: original.id)
                ).environment(ThemeStore()),
                named: "composer-aviso-salvar-ref",
                size: CGSize(width: 820, height: 660),
                theme: .tinta
            )
        )
        #expect(
            comAviso.pixelsDiffering(from: semAviso) > 0,
            "o cartão de sair não desenhou por cima da janela"
        )
        // O Salvar do cartão é acento no miolo; o Enviar do rodapé fica embaixo.
        #expect(Self.hasAccentFill(in: comAviso, yRange: 250...430, width: 820))
    }

    /// Sem mensagem casada não há para onde ir, e o botão não pode fingir que
    /// há: a ação sai sem mexer em nada e o botão desenha apagado.
    @Test("sem mensagem de origem o botão não mexe em nada")
    func withoutOriginNothingHappens() async throws {
        let store = await loaded()
        // Um compromisso cujo detalhe não casa com assunto nenhum da caixa.
        let window = EventWindow(store: store, itemID: "nao-existe")
        #expect(window.originMessageID == nil)

        let before = store.revealCount
        window.revealOriginMessage()
        #expect(store.revealCount == before)
    }

    /// "Reagendar" saiu. O rodapé da 04 desenha **cinco** pastilhas — Entrar,
    /// Encaminhar, Remover, Email e o × de fechar —, e o sexto, mudo, não está
    /// mais lá.
    ///
    /// Contado no desenho: numa varredura horizontal na altura dos botões, cada
    /// pastilha é um trecho de cor diferente do fundo do rodapé. Com o botão
    /// mudo de volta a mesma varredura dá seis.
    @Test("o rodapé desenha cinco botões, sem o «Reagendar» mudo")
    func footerHasFourButtons() async throws {
        let store = await loaded()
        let rep = try #require(
            Render.snapshot(
                EventWindow(store: store, itemID: "e2").environment(ThemeStore()),
                named: "evento-04-rodape",
                size: CGSize(width: 560, height: 700),
                theme: .tinta
            )
        )
        #expect(Self.pills(in: rep, y: 660, width: 560) == 5)
    }

    // MARK: - "Entrar", que não fazia nada

    /// O compromisso vindo de convite, montado à mão para a janela ter o que
    /// desenhar. `link` nulo é o convite sem sala — o caso em que o botão
    /// "Entrar" **não pode existir**.
    static func detalheDeConvite(
        link: String?,
        extras: [EventPerson] = [],
        assuntoDoEmail: String = "Convite: DreamSquad <> Vantion",
        descricao: String? = nil
    ) -> EventDetail {
        EventDetail(
            place: EventPlace.semLocal, link: link,
            organizer: EventPerson(
                name: "Favini", address: "favini@vantion.com.br",
                role: "organizador", status: .yes
            ),
            people: extras,
            note: "Do convite por email · conta vantion",
            recurrence: "Evento único", notice: "Sem alerta",
            agenda: [],
            thread: [
                EventThreadEntry(
                    when: "21 de jul., 14:30", who: "Favini",
                    what: assuntoDoEmail, kind: .email
                )
            ],
            descricao: descricao
        )
    }

    static func loja(_ detail: EventDetail) async -> MailStore {
        let item = AgendaItem(
            id: "email-m1", title: "DreamSquad", startMinute: 594, endMinute: 644,
            accountID: "zoho", dayOffset: 0,
            calendarUID: "u1", calendarSequence: 0, detail: detail
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: Fixtures.accounts, messages: [], agenda: [item])
        )
        await store.load()
        return store
    }

    /// Onde o rodapé desenha os botões, num render de 700 de altura: recuo de
    /// baixo 15 + metade dos 30pt do botão.
    private static let yDoRodape: CGFloat = 700 - 30

    /// **O defeito mais caro da tela do dono.** O botão em destaque da janela
    /// chamava `UNIWindow.logSend("Abriria …")`: uma linha no `stderr`, nada na
    /// tela. A pessoa clicava em cima da hora e a reunião não abria.
    ///
    /// Provado com um clique de verdade — `NSEvent.mouseEvent` entregue por
    /// `NSWindow.sendEvent` a uma janela a −50.000pt, o mesmo cano da M3-11.
    /// Nenhum navegador é aberto: o abridor entra pela porta (`abreLink`) e só
    /// anota o endereço.
    ///
    /// Cai por mutação: devolver a ação ao `logSend` (ou esvaziá-la) deixa a
    /// caixa vazia.
    @Test("«Entrar» abre o link da reunião no navegador")
    func entrarAbreALink() async throws {
        let store = await Self.loja(Self.detalheDeConvite(link: "https://meet.google.com/abc-defg-hij"))
        let caixa = CaixaDeLinks()

        var janela = EventWindow(store: store, itemID: "email-m1")
        janela.abreLink = { caixa.abertos.append($0) }

        CliqueDeEnsaio.em(
            janela,
            size: CGSize(width: 560, height: 700),
            aY: Self.yDoRodape, x: 40
        )

        #expect(caixa.abertos.map(\.absoluteString) == ["https://meet.google.com/abc-defg-hij"])
    }

    @Test("Meet enterrado na descrição ainda cria «Entrar» e cartão próprio")
    func entrarUsaLinkDaDescricao() async throws {
        let blocoDoGoogle = """
            -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
            --
            Entrar com o Google Meet: https://meet.google.com/us-qnjh-suq

            Saiba mais sobre o Meet em: https://support.google.com/a/users/answer/9282720

            Não edite esta seção.
            -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
            --
            """
        let detail = Self.detalheDeConvite(link: nil, descricao: blocoDoGoogle)
        let store = await Self.loja(detail)
        let caixa = CaixaDeLinks()
        var janela = EventWindow(store: store, itemID: "email-m1")
        janela.abreLink = { caixa.abertos.append($0) }

        let rep = try #require(Render.snapshot(
            janela.environment(ThemeStore()),
            named: "evento-04-meet-da-descricao",
            size: CGSize(width: 560, height: 700),
            theme: .tinta
        ))
        #expect(Self.pills(in: rep, y: 660, width: 560) == 5)

        CliqueDeEnsaio.em(
            janela,
            size: CGSize(width: 560, height: 700),
            aY: Self.yDoRodape,
            x: 40
        )

        #expect(caixa.abertos.map(\.absoluteString) == ["https://meet.google.com/us-qnjh-suq"])
    }

    /// Sem sala reconhecida o botão **não aparece** — é o que o protótipo
    /// desenha (`sc-if ev.hasLink`) e o que o resto do app faz quando não há
    /// para onde ir. O rodapé volta a quatro pastilhas: Encaminhar, Remover,
    /// Email e o ×.
    @Test("sem link de reunião o «Entrar» não existe")
    func semLinkSemEntrar() async throws {
        let store = await Self.loja(Self.detalheDeConvite(link: nil))
        let rep = try #require(
            Render.bitmap(
                EventWindow(store: store, itemID: "email-m1"),
                size: CGSize(width: 560, height: 700), theme: .tinta
            )
        )
        #expect(Self.pills(in: rep, y: 660, width: 560) == 4)
    }

    /// E um "link" que não se abre no navegador é a mesma coisa que não ter:
    /// um botão que promete o navegador e entrega nada é o defeito de volta.
    @Test("um «link» que não é endereço também não acende o botão")
    func linkQueNaoAbreNaoAcende() async throws {
        let store = await Self.loja(Self.detalheDeConvite(link: "Sala 3, 4º andar"))
        let rep = try #require(
            Render.bitmap(
                EventWindow(store: store, itemID: "email-m1"),
                size: CGSize(width: 560, height: 700), theme: .tinta
            )
        )
        #expect(Self.pills(in: rep, y: 660, width: 560) == 4)
    }

    // MARK: - As seções que nascem recolhidas

    /// **Oito participantes tomavam a janela inteira.** Recolhida, a seção
    /// mostra o organizador e mais nada — e a prova é que trocar quem são os
    /// sete escondidos não muda um pixel do desenho.
    ///
    /// Cai por mutação: tirar o `EventSections.visibleGuests` (desenhar
    /// `guests` inteiro) põe os sete na tela, e os dois desenhos divergem.
    @Test("a seção de participantes nasce recolhida")
    func participantesNascemRecolhidos() async throws {
        func janela(_ nomes: [String]) async -> NSBitmapImageRep? {
            let extras = nomes.map {
                EventPerson(
                    name: $0, address: "\($0.lowercased())@vantion.com.br",
                    role: "convidado", status: .pending
                )
            }
            let store = await Self.loja(Self.detalheDeConvite(link: nil, extras: extras))
            return Render.bitmap(
                EventWindow(store: store, itemID: "email-m1"),
                size: CGSize(width: 560, height: 700), theme: .tinta
            )
        }

        // Mesma contagem (o cabeçalho diz "· 8" nos dois), gente diferente.
        let time = try #require(await janela(
            ["Marcos", "Ana", "Bruno", "Carla", "Diego", "Elis", "Fabio"]
        ))
        let outroTime = try #require(await janela(
            ["Zilda", "Yara", "Xavier", "Walter", "Vera", "Ulisses", "Tania"]
        ))
        #expect(
            time.pixelsDiffering(from: outroTime) == 0,
            "a janela desenhou os participantes que a seção recolhida esconde"
        )
    }

    /// A mesma prova para "o que gerou este compromisso": recolhida, o assunto
    /// do email não está na tela — só o cabeçalho, que diz de quando ele é.
    @Test("a seção «o que gerou» nasce recolhida")
    func oQueGerouNasceRecolhido() async throws {
        func janela(_ assunto: String) async -> NSBitmapImageRep? {
            let store = await Self.loja(
                Self.detalheDeConvite(link: nil, assuntoDoEmail: assunto)
            )
            return Render.bitmap(
                EventWindow(store: store, itemID: "email-m1"),
                size: CGSize(width: 560, height: 700), theme: .tinta
            )
        }
        let um = try #require(await janela("Convite: DreamSquad <> Vantion"))
        let outro = try #require(await janela("Outro assunto completamente diferente"))
        #expect(
            um.pixelsDiffering(from: outro) == 0,
            "a janela desenhou o histórico que a seção recolhida esconde"
        )
    }

    /// O acento do Salvar no miolo da janela — prova de que o aviso de sair
    /// é o cartão desenhado, não o diálogo nativo.
    private static func hasAccentFill(
        in rep: NSBitmapImageRep, yRange: ClosedRange<Int>, width: Int
    ) -> Bool {
        let fill = Theme.tinta.accent
        for y in yRange {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - fill.red) < 0.08,
                   abs(color.greenComponent - fill.green) < 0.08,
                   abs(color.blueComponent - fill.blue) < 0.08
                {
                    return true
                }
            }
        }
        return false
    }

    /// O magenta do Remover no miolo da janela — prova de que o aviso é o
    /// cartão desenhado, não o diálogo nativo (que o harness nem renderiza).
    private static func hasRemoveFill(
        in rep: NSBitmapImageRep, yRange: ClosedRange<Int>, width: Int
    ) -> Bool {
        let fill = Theme.tinta.remove
        for y in yRange {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - fill.red) < 0.08,
                   abs(color.greenComponent - fill.green) < 0.08,
                   abs(color.blueComponent - fill.blue) < 0.08
                {
                    return true
                }
            }
        }
        return false
    }

    /// Quantas pastilhas a linha `y` atravessa: cada entrada num trecho de cor
    /// diferente do fundo do rodapé conta uma.
    private static func pills(in rep: NSBitmapImageRep, y: Int, width: Int) -> Int {
        guard let background = rep.colorAt(x: 2, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        func differs(_ color: NSColor?) -> Bool {
            guard let c = color?.usingColorSpace(.sRGB) else { return false }
            return abs(c.redComponent - background.redComponent) > 0.01
                || abs(c.greenComponent - background.greenComponent) > 0.01
                || abs(c.blueComponent - background.blueComponent) > 0.01
        }
        var count = 0
        var inside = false
        for x in 0..<width {
            let now = differs(rep.colorAt(x: x, y: y))
            if now && !inside { count += 1 }
            inside = now
        }
        return count
    }
}

/// Onde o abridor injetado anota o que lhe pediram. Classe, e não `var` local:
/// o fechamento que a janela guarda precisa escrever num lugar que sobreviva ao
/// clique — e nenhum navegador é aberto em teste nenhum deste projeto.
@MainActor
final class CaixaDeLinks {
    var abertos: [URL] = []
}
