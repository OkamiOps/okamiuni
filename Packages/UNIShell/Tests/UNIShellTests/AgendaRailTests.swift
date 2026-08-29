import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("AgendaRail")
struct AgendaRailTests {

    private let layout = AgendaRail.Layout(
        pointsPerMinute: 0.78
    )

    @Test("a trilha tem a largura do design")
    func width() {
        #expect(AgendaRail.width == 262)
    }

    @Test("um compromisso das 09:30 às 10:00 cai na posição certa")
    func placesEvent() {
        let standup = AgendaItem(
            id: "e1", title: "Standup produto",
            startMinute: 570, endMinute: 600, accountID: "zoho"
        )
        // A trilha cobre o dia inteiro agora (00:00 a 24:00) — o desconto de
        // 480 (08:00) que existia quando a faixa começava lá sumiu junto:
        // 09:30 são 570 minutos desde a meia-noite -> 570 × 0.78 = 444.6pt.
        #expect(layout.offset(for: standup) == 444.6)
        // 30 min × 0.78 - 3 = 23.4 - 3 = 20.4pt, mas mínimo é 42 para modo tight
        #expect(layout.height(for: standup) == 42)
    }

    @Test("compromissos curtos ainda têm altura clicável")
    func minimumHeight() {
        let tiny = AgendaItem(
            id: "x", title: "Rápido",
            startMinute: 600, endMinute: 605, accountID: "zoho"
        )
        // 5 min × 0.78 - 3 = 3.9 - 3 = 0.9pt, deve subir para 42 (tight threshold)
        #expect(layout.height(for: tiny) == 42)
    }

    /// Antes a trilha ia só de 480 (08:00) a 1140 (19:00) — o dono conectou
    /// uma conta real e viu que um compromisso depois das 19h simplesmente
    /// não tinha onde desenhar. "O dia não acaba às 18" foi a fala dele.
    /// Mudança consciente: o literal e o comentário do teste anterior
    /// afirmavam a faixa velha, e agora afirmam o dia inteiro.
    @Test("a trilha cobre o dia inteiro (00:00 a 24:00)")
    func totalHeight() {
        // 1440 min × 0.78 = 1123.2pt (com tolerância de floating point)
        #expect(abs(layout.totalHeight - 1_123.2) < 0.01)
    }

    @Test("o rótulo de início é HH:MM")
    func startLabel() {
        let item = AgendaItem(id: "e", title: "T", startMinute: 570, endMinute: 600, accountID: "z")
        #expect(item.startLabel == "09:30")
    }

    @Test("nextUpLabel mostra o compromisso em andamento")
    func nextUpLabelRunning() {
        let items = Fixtures.agenda
        let now = 580  // 09:40, meio do Standup (570-600)
        // Standup rodando, termina às 10:00
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "agora: Standup produto · termina 10:00")
    }

    @Test("nextUpLabel mostra o próximo compromisso")
    func nextUpLabelUpcoming() {
        let items = Fixtures.agenda
        let now = 630  // 10:30, depois do Standup, antes da 1:1 (660-705)
        // Próximo em 30 min
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "em 30 min: 1:1 Marina Duarte")
    }

    @Test("nextUpLabel diz 'nada mais hoje' quando sem eventos restantes")
    func nextUpLabelNone() {
        let items = Fixtures.agenda
        let now = 1100  // 18:20, depois do último (990-1080)
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "nada mais hoje")
    }

    @Test("nextUpLabel com agenda vazia")
    func nextUpLabelEmpty() {
        let items: [AgendaItem] = []
        let now = 600
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "nada mais hoje")
    }

    @Test("nextUpLabel no exato início de um compromisso")
    func nextUpLabelExactStart() {
        let items = Fixtures.agenda
        let now = 570  // exatamente 09:30, início do Standup
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        #expect(label == "agora: Standup produto · termina 10:00")
    }

    @Test("nextUpLabel no exato fim de um compromisso")
    func nextUpLabelExactEnd() {
        let items = Fixtures.agenda
        let now = 600  // exatamente 10:00, fim do Standup
        let label = AgendaRail.nextUpLabel(for: items, now: now)
        // Já terminou, próximo é 1:1 em 60 min
        #expect(label == "em 60 min: 1:1 Marina Duarte")
    }

    @Test("altura mínima é 42 para modo tight")
    func tightThreshold() {
        // Evento que dá exatamente na borda: 54 min × 0.78 - 3 = 42.12 - 3 = 39.12 < 42
        let item = AgendaItem(
            id: "x", title: "T",
            startMinute: 500, endMinute: 554, accountID: "z"
        )
        #expect(layout.height(for: item) == 42)

        // Evento que não ativa tight: 55 min × 0.78 - 3 = 42.9 - 3 = 39.9 < 42 ainda
        let item2 = AgendaItem(
            id: "x", title: "T",
            startMinute: 500, endMinute: 555, accountID: "z"
        )
        #expect(layout.height(for: item2) == 42)

        // Evento maior que 42: 60 min × 0.78 - 3 = 46.8 - 3 = 43.8 > 42
        let item3 = AgendaItem(
            id: "x", title: "T",
            startMinute: 500, endMinute: 560, accountID: "z"
        )
        #expect(abs(layout.height(for: item3) - 43.8) < 0.01)
    }

    /// Mutação vermelha do conserto: com a faixa velha (480-1140), um
    /// compromisso às 05:00 desenhava com `offset` negativo (fora da trilha,
    /// para cima) e um às 20:00 desenhava além de `totalHeight` (fora da
    /// trilha, para baixo) — os dois sumiam. Com o dia inteiro, os dois têm
    /// onde desenhar: `offset` cai dentro de `0...totalHeight`. Se a faixa
    /// voltasse a 480-1140, `early` voltaria a ser negativo e `late`
    /// voltaria a estourar `totalHeight`.
    @Test("um compromisso de madrugada ou depois das 19h ainda desenha dentro da trilha")
    func offsetsCoverTheWholeDay() {
        let early = AgendaItem(id: "x", title: "Cedo", startMinute: 300, endMinute: 400, accountID: "z")
        let late = AgendaItem(id: "x", title: "Tarde", startMinute: 1200, endMinute: 1300, accountID: "z")

        #expect(layout.offset(for: early) == 234)     // 05:00 → 300 × 0.78
        #expect(layout.offset(for: late) == 936)       // 20:00 → 1200 × 0.78
        #expect(layout.offset(for: early) >= 0)
        #expect(layout.offset(for: late) <= layout.totalHeight)
    }

    @Test("cabeçalho da agenda formata a data corretamente")
    func headerDateFormatting() {
        let dateString = AgendaRail.headerDateString(Fixtures.today)
        // Fixtures.today é terça-feira, 25 de agosto de 2026
        #expect(dateString == "Terça-feira, 25 de agosto")
    }

    @Test("rótulo de duração — minutos para N < 90")
    func durationMinutes() {
        let items = Fixtures.agenda
        // now = 720 (12:00), almoço às 12:30 (750) → 30 min
        let label = AgendaRail.nextUpLabel(for: items, now: 720)
        #expect(label == "em 30 min: Almoço — bloqueado")
    }

    @Test("rótulo de duração — 89 min (limite inferior, sem formato em horas)")
    func duration89Minutes() {
        let items = Fixtures.agenda
        // now = 901 (15:01), foco às 16:30 (990) → 89 min
        let label = AgendaRail.nextUpLabel(for: items, now: 901)
        #expect(label == "em 89 min: Foco: proposta TransRota")
    }

    @Test("rótulo de duração — 90 min (limite superior, formato 1h30)")
    func duration90Minutes() {
        let items = Fixtures.agenda
        // now = 900 (15:00), foco às 16:30 (990) → 90 min = 1h30
        let label = AgendaRail.nextUpLabel(for: items, now: 900)
        #expect(label == "em 1h30: Foco: proposta TransRota")
    }

    @Test("rótulo de duração — 271 min (1:1 14h até Foco 16:30)")
    func duration271Minutes() {
        let items = Fixtures.agenda
        // Usa item customizado para testar número grande de minutos
        let customItem = AgendaItem(id: "x", title: "Evento longe",
                                   startMinute: 990, endMinute: 1000, accountID: "z")
        let label = AgendaRail.nextUpLabel(for: [customItem], now: 660)
        // 990 - 660 = 330 min = 5h30
        #expect(label == "em 5h30: Evento longe")
    }

    // MARK: - Calha das horas (Task P, defeito 1 e 3)

    @Test("a calha e o recuo dos cartões vêm do protótipo")
    func gutterMatchesPrototype() {
        // O defeito da Task P: o cartão começava em 24pt, dentro da calha de
        // 26pt, e escondia "10", "11", "13", "14" e "17" atrás do bloco.
        //
        // O que trava o defeito são estas literais, não uma relação entre elas:
        // `eventLeading` é *definido* como `labelGutter + gutterGap`, então
        // qualquer asserção ligando os três é verdadeira por construção e
        // passaria com a calha de volta em 2pt e os rótulos cobertos.
        //
        // Protótipo: linha da hora com `gap: 6px`, cartão com `right: 2px`.
        // A calha tem 30 e não os 26 declarados no span porque o texto do
        // protótipo é "08:00", que em mono 9pt não cabe em 26.
        #expect(layout.gutterGap == 6)
        #expect(layout.eventTrailing == 2)
        #expect(layout.labelGutter == 30)
        #expect(layout.eventLeading == 36)
    }

    @Test("o rótulo da hora é HH:MM, como o fmt() do protótipo")
    func hourLabelIsHourAndMinute() {
        #expect(AgendaRail.hourLabel(minuteOfDay: 480) == "08:00")
        #expect(AgendaRail.hourLabel(minuteOfDay: 540) == "09:00")
        #expect(AgendaRail.hourLabel(minuteOfDay: 1080) == "18:00")
        // O mesmo fmt() serve para qualquer minuto, não só a hora cheia.
        #expect(AgendaRail.hourLabel(minuteOfDay: 705) == "11:45")
        #expect(AgendaRail.hourLabel(minuteOfDay: 0) == "00:00")
    }

    @Test("a calha cabe o rótulo que o protótipo escreve")
    func gutterFitsTheLabel() {
        // "08:00" em mono 9pt mede ~27pt: a calha tem de ser maior que isso,
        // senão o rótulo trunca — foi por medir esse 27 que ela saiu de 26.
        let widest = AgendaRail.hourLabel(minuteOfDay: 1080)
        #expect(widest.count == 5)
        #expect(layout.labelGutter >= 30)
    }

    @Test("a rolagem inicial deixa a manhã (~08:00) visível, não a meia-noite")
    func initialScrollTargetShowsMorning() {
        // A trilha agora abre em 00:00, e sem uma rolagem inicial a pessoa
        // veria a madrugada vazia em vez dos compromissos do dia. O alvo é
        // fixo em 08:00 — 480 × 0.78 — e não em "agora": a trilha é o resumo
        // do dia inteiro, útil de manhã, de tarde ou de madrugada.
        #expect(abs(layout.initialScrollTarget - 374.4) < 0.01)
    }

    @Test("o marcador de agora encosta na calha em vez de atravessá-la")
    func nowMarkerStartsAfterGutter() {
        // Protótipo: `nowStyle … left: 26px`. Zero faria o traço vermelho passar
        // por cima do rótulo "12", que era o defeito 3.
        #expect(layout.nowMarkerLeading == layout.labelGutter)
        #expect(layout.nowMarkerLeading > 0)
    }

    @Test("minuto das fixtures é sempre 720, independente do fuso da máquina")
    func fixturesNowMinuteIsTimezoneIndependent() {
        // Fixtures.nowMinute é uma constante (720 = 12:00)
        #expect(Fixtures.nowMinute == 720)

        // Com esse minuto, o rótulo deve refletir o meio-dia (Almoço em 30 min)
        let label = AgendaRail.nextUpLabel(for: Fixtures.agenda, now: Fixtures.nowMinute)
        #expect(label == "em 30 min: Almoço — bloqueado")

        // Mesmo se usarmos Fixtures.today (que é um instante, não um minuto),
        // a injeção em InboxScreen deve usar nowMinute, não derivar de hoje
        let headerDate = AgendaRail.headerDateString(Fixtures.today)
        #expect(headerDate == "Terça-feira, 25 de agosto")
    }

    // MARK: - Task AJ, conserto 1: a trilha respeita a conta selecionada

    /// Consertava `AgendaRail.swift:114`, que lia `store.agenda` em vez de
    /// `store.visibleAgenda`: a única das seis superfícies de agenda que não
    /// filtrava por conta. Selecionar `icloud` na barra lateral continuava
    /// mostrando "Standup produto", "1:1 Marina Duarte" e "Revisão do
    /// contrato" — todos `zoho` — e "Foco: proposta TransRota" (`host`).
    @Test("com uma conta selecionada, a trilha só mostra compromissos dessa conta")
    @MainActor
    func todayItemsRespectAccountFilter() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        // Confirma a mistura antes de filtrar: sem isto o teste passaria
        // mesmo sem filtro nenhum, porque não haveria item de outra conta
        // para vazar.
        let unfiltered = AgendaRail(store: store, now: Fixtures.nowMinute, headerDate: Fixtures.today)
        try #require(unfiltered.todayItems.contains { $0.accountID == "zoho" })

        store.select(account: "icloud")
        let rail = AgendaRail(store: store, now: Fixtures.nowMinute, headerDate: Fixtures.today)

        #expect(rail.todayItems.isEmpty == false)
        #expect(rail.todayItems.allSatisfy { $0.accountID == "icloud" })
        #expect(rail.todayItems.contains { $0.accountID == "zoho" } == false)
    }

    // MARK: - Task AJ, conserto 2: "Vindo do email" vem do store

    /// Consertava `AgendaRail.swift:300`, que lia `Fixtures.pendingItems`
    /// direto — a única `View` de produção da área que não passava pelo
    /// `store`. A seção continuava citando um item de `zoho` e um de `host`
    /// com qualquer conta selecionada.
    @Test("'Vindo do email' filtra pela conta selecionada, como o resto da agenda")
    @MainActor
    func pendingItemsComeFromTheStore() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        // A store carregou os pendentes da fonte, não de `Fixtures` direto.
        #expect(store.pendingItems == Fixtures.pendingItems)

        store.select(account: "zoho")
        #expect(store.visiblePendingItems.isEmpty == false)
        #expect(store.visiblePendingItems.allSatisfy { $0.accountID == "zoho" })

        store.select(account: "host")
        #expect(store.visiblePendingItems.allSatisfy { $0.accountID == "host" })
        #expect(store.visiblePendingItems.contains { $0.accountID == "zoho" } == false)
    }

    /// A metade que `pendingItemsComeFromTheStore` sozinho não prova: que a
    /// `View` de fato **lê** `store.visiblePendingItems`, e não
    /// `Fixtures.pendingItems` direto com o filtro por baixo dela. `MailStore`
    /// já filtra certo mesmo se `AgendaRail` ignorar — só renderizar e medir
    /// pega essa regressão específica.
    @Test("com uma conta selecionada, 'Vindo do email' não desenha a bolinha da outra conta")
    @MainActor
    func pendingSectionRendersOnlyTheSelectedAccount() async throws {
        let items = [
            PendingItem(id: "p1", text: "Um", accountID: "zoho"),
            PendingItem(id: "p2", text: "Dois", accountID: "host"),
        ]
        let source = InMemoryMailSource(
            accounts: Fixtures.accounts, messages: [], agenda: [], pendingItems: items
        )
        let store = MailStore(source: source)
        await store.load()
        store.select(account: "zoho")

        let rail = AgendaRail(store: store, now: Fixtures.nowMinute, headerDate: Fixtures.today)
        let size = CGSize(width: AgendaRail.width, height: 200)
        let rep = try #require(Render.bitmap(rail.pendingSection, size: size, theme: .tinta, scale: 1))
        let pixels = HairlineThicknessTests.Pixels(rep: rep)

        let zoho = TokenColor(red: 0x3F / 255, green: 0x6A / 255, blue: 0xA1 / 255)
        let host = TokenColor(red: 0x39 / 255, green: 0x78 / 255, blue: 0x52 / 255)
        let x = 18

        func appears(_ target: TokenColor) -> Bool {
            (0..<Int(size.height)).contains {
                HairlineThicknessTests.levels(pixels.color(x, $0), target) < 20
            }
        }

        #expect(appears(zoho), "a bolinha de zoho, a conta filtrada, devia aparecer")
        #expect(appears(host) == false, "a bolinha de host vazou apesar do filtro de conta")
    }

    // MARK: - Task AJ, conserto 3: um só `.padding(.bottom, 15)` para a seção

    /// Consertava `AgendaRail.swift:318`: `.padding(.bottom, 15)` encadeado
    /// direto no `ForEach` vale **por elemento**, não uma vez. Com dois itens
    /// isso empurrava 15pt extras atrás de cada um, e a folga entre
    /// "Confirmar call…" e "Renovar domínio…" media 23pt em vez dos 8pt do
    /// protótipo (4 de cada item, a seção contribuindo só uma vez).
    ///
    /// Mede em pixel a distância entre a bolinha colorida do primeiro item e
    /// a do segundo, numa coluna que só passa pelas duas bolinhas — o resto
    /// da seção nessa coluna é fundo `surface2`. Provado quebrando: revertida
    /// a correção (padding de volta no `ForEach`, sem o `VStack` que o
    /// envolve), a mesma medida sobe para a faixa dos 23pt — ver o relatório.
    @Test("a folga entre dois itens de 'Vindo do email' é ~8pt, não 23")
    @MainActor
    func pendingSectionGapMatchesPrototype() async throws {
        // Texto curto de propósito, para não quebrar linha: as fixtures reais
        // ("Confirmar call de contrato com Marina — quinta 15h") ocupam duas
        // linhas na largura de 262pt, e a bolinha de cada item fica presa ao
        // topo da primeira linha — a distância entre as duas bolinhas passaria
        // a incluir a altura da segunda linha de texto, que não é o que este
        // teste mede. O defeito e o conserto são sobre `.padding(.bottom, 15)`
        // no `ForEach`, não sobre quebra de linha, então isolar isso aqui é
        // fiel ao defeito descrito no relatório.
        let items = [
            PendingItem(id: "p1", text: "Um", accountID: "zoho"),
            PendingItem(id: "p2", text: "Dois", accountID: "host"),
        ]
        let source = InMemoryMailSource(
            accounts: Fixtures.accounts, messages: [], agenda: [], pendingItems: items
        )
        let store = MailStore(source: source)
        await store.load()
        let rail = AgendaRail(store: store, now: Fixtures.nowMinute, headerDate: Fixtures.today)

        let size = CGSize(width: AgendaRail.width, height: 200)
        let rep = try #require(Render.bitmap(rail.pendingSection, size: size, theme: .tinta, scale: 1))
        let pixels = HairlineThicknessTests.Pixels(rep: rep)

        // As cores exatas das bolinhas: `tintLightHex` de `zoho` e `host`
        // (`Fixtures.swift:22, 31`). Procurar por elas, e não por "qualquer
        // pixel que não seja o fundo", evita confundir a bolinha com o texto
        // do cabeçalho "VINDO DO EMAIL" — que também não é `surface2`.
        let zoho = TokenColor(red: 0x3F / 255, green: 0x6A / 255, blue: 0xA1 / 255)
        let host = TokenColor(red: 0x39 / 255, green: 0x78 / 255, blue: 0x52 / 255)

        // A bolinha (5×5) fica em `x ∈ [16, 21]` — recuo horizontal de 16 da
        // seção, primeiro elemento do HStack. x=18 cruza as duas bolinhas e
        // fica longe do texto, que começa depois do `spacing: 8` do HStack.
        let x = 18

        func firstBand(matching target: TokenColor) -> (start: Int, end: Int)? {
            var runStart: Int?
            for y in 0..<Int(size.height) {
                let matches = HairlineThicknessTests.levels(pixels.color(x, y), target) < 20
                if matches, runStart == nil {
                    runStart = y
                } else if !matches, let start = runStart {
                    return (start, y - 1)
                }
            }
            if let start = runStart { return (start, Int(size.height) - 1) }
            return nil
        }

        let dot1 = try #require(firstBand(matching: zoho), "não achei a bolinha de zoho na coluna x=\(x)")
        let dot2 = try #require(firstBand(matching: host), "não achei a bolinha de host na coluna x=\(x)")
        #expect(dot1.start < dot2.start, "a bolinha de zoho devia vir antes da de host")

        let gap = dot2.start - dot1.end - 1
        // A bolinha não fica colada ao topo da linha (`.firstTextBaseline`
        // com `.padding(.top, 2)`), então esta distância não é os 8pt nus da
        // folga entre itens — carrega também o resto da altura da linha de
        // texto de cada lado. O que importa não é o valor absoluto, e sim
        // que ele não inclua os 15pt extras que o `ForEach` vazava por
        // elemento: com o defeito de volta (padding no `ForEach`, sem o
        // `VStack` em volta), esta mesma medida sobe para a faixa dos 30+pt.
        #expect(gap > 0)
        #expect(gap < 25, "folga medida foi \(gap)pt — o defeito soma mais 15pt aqui")
    }
}
