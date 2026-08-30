import Testing
import Foundation
import UNICore

/// O gesto de arrastar a linha, provado onde ele costuma errar: **nas
/// fronteiras**. Cada limiar tem um teste um ponto antes e outro um ponto
/// depois.
@Suite("Arraste lateral da linha")
struct SwipeActionTests {

    private func message(
        id: String = "m1",
        accountID: String = "zoho",
        bucket: TriageBucket = .today,
        isRead: Bool = false,
        isFlagged: Bool = false,
        name: String = "Marina Duarte",
        address: String = "marina@clientepremium.com",
        folderIDs: [String] = []
    ) -> Message {
        Message(
            id: id, accountID: accountID,
            from: Contact(name: name, address: address),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: bucket, isRead: isRead,
            summary: nil, detectedEvent: nil, isFlagged: isFlagged,
            folderIDs: folderIDs
        )
    }

    // MARK: - As duas colunas novas

    /// Elas entram no rol configurável, e não no padrão: quem já escolheu os
    /// lados dele não vê a escolha mudar sozinha.
    @Test("apagar e sinalizar entram no rol de escolha, e o padrão continua o mesmo")
    func newActionsAreOfferedButNotImposed() {
        #expect(SwipeAction.allCases.contains(.trash))
        #expect(SwipeAction.allCases.contains(.toggleFlag))
        #expect(SwipeConfiguration.default.leading == [.archive, .toggleRead])
        #expect(SwipeConfiguration.default.trailing == [.later, .today])
    }

    @Test("Mover para persistido escolhe a operação real de cada protocolo")
    func moveDestinationUsesProtocolCorrectly() throws {
        let inbox = MailFolder(
            id: "zoho/INBOX", accountID: "zoho", serverName: "INBOX",
            displayName: "Entrada", role: .inbox
        )
        let label = MailFolder(
            id: "zoho/Label_42", accountID: "zoho", serverName: "Label_42",
            displayName: "Clientes", role: .other
        )
        let gmail = try #require(SwipeMoveDestination(gmailLabel: label, removing: inbox))
        let gmailMessage = message(folderIDs: [inbox.id, "zoho/Label_VIP"])
        let configuration = SwipeConfiguration(
            leading: [.moveToDestination], trailing: [], leadingDestination: gmail
        )

        #expect(SwipeAction.moveToDestination.command(for: gmailMessage, destination: gmail)
            == .moveGmailMessage(messageID: gmailMessage.id, from: inbox, to: label))
        #expect(!SwipeAction.moveToDestination.isNoOp(for: gmailMessage, destination: gmail))
        #expect(SwipeGesture.release(
            translation: CGSize(width: 300, height: 0), configuration: configuration,
            message: gmailMessage
        ) == .fire(.moveToDestination, .leading))

        var machine = SwipeGestureMachine()
        let context = SwipeContext(configuration: configuration, message: gmailMessage)
        _ = machine.dragChanged(
            translation: CGSize(width: 300, height: 0), startLocation: .zero, context
        )
        let outcome = machine.dragEnded(
            translation: CGSize(width: 300, height: 0), startLocation: .zero, context
        )
        #expect(outcome.fired == .moveToDestination)
        #expect(outcome.firedSide == .leading)

        let source = MailFolder(
            id: "zoho/INBOX.Financeiro", accountID: "zoho", serverName: "INBOX.Financeiro",
            displayName: "Financeiro", role: .other
        )
        let destination = MailFolder(
            id: "zoho/INBOX.Clientes", accountID: "zoho", serverName: "INBOX.Clientes",
            displayName: "Clientes", role: .other
        )
        let imap = SwipeMoveDestination(imapFolder: destination)
        let imapMessage = message(folderIDs: [source.id])
        #expect(SwipeAction.moveToDestination.command(for: imapMessage, destination: imap)
            == .placeMessage(messageID: imapMessage.id, folder: destination, mode: .move))
    }

    @Test("O destino torna a ação de gesto persistível sem alterar preferências antigas")
    @MainActor
    func moveDestinationPersistsAlongsideLegacyArrays() throws {
        let name = "okamiuni.swipe.test.destination"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        // Uma configuração já existente, gravada antes desta funcionalidade.
        suite.set([SwipeAction.archive.rawValue], forKey: "okamiuni.swipe.leading")

        let inbox = MailFolder(
            id: "zoho/INBOX", accountID: "zoho", serverName: "INBOX",
            displayName: "Entrada", role: .inbox
        )
        let label = MailFolder(
            id: "zoho/Label_42", accountID: "zoho", serverName: "Label_42",
            displayName: "Clientes", role: .other
        )
        let destination = try #require(SwipeMoveDestination(gmailLabel: label, removing: inbox))

        let first = SwipeSettingsStore(defaults: suite)
        #expect(first.configuration.leading == [.archive])
        first.setMoveDestination(destination, on: .trailing)

        let reopened = SwipeSettingsStore(defaults: suite)
        #expect(reopened.configuration.leading == [.archive])
        #expect(reopened.configuration.trailing.contains(.moveToDestination))
        #expect(reopened.configuration.destination(on: .trailing) == destination)

        reopened.setActions([.today], on: .trailing)
        #expect(reopened.configuration.destination(on: .trailing) == nil)

        suite.removePersistentDomain(forName: name)
    }

    @Test("Mover escolhe um destino por conta sem vazar para a outra")
    @MainActor
    func moveDestinationsAreScopedToAccounts() throws {
        let name = "okamiuni.swipe.test.destinations-by-account"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)

        let gmailInbox = MailFolder(
            id: "a/INBOX", accountID: "a", serverName: "INBOX",
            displayName: "Entrada", role: .inbox
        )
        let gmailLabel = MailFolder(
            id: "a/Projetos", accountID: "a", serverName: "Projetos",
            displayName: "Projetos", role: .other
        )
        let a = try #require(SwipeMoveDestination(
            gmailLabel: gmailLabel, removing: gmailInbox, accountLabel: "trabalho@okamiops.com"
        ))
        let imapFolder = MailFolder(
            id: "b/Clientes", accountID: "b", serverName: "Clientes",
            displayName: "Clientes", role: .other
        )
        let b = SwipeMoveDestination(imapFolder: imapFolder, accountLabel: "pessoal@example.com")

        let store = SwipeSettingsStore(defaults: suite)
        #expect(store.setMoveDestination(a, on: .leading, for: "a"))
        #expect(store.setMoveDestination(b, on: .leading, for: "b"))
        #expect(!store.setMoveDestination(a, on: .leading, for: "b"))

        let aMessage = message(id: "a1", accountID: "a", folderIDs: [gmailInbox.id])
        let bMessage = message(id: "b1", accountID: "b", folderIDs: ["b/INBOX"])
        let otherMessage = message(id: "c1", accountID: "c", folderIDs: ["c/INBOX"])
        let configuration = store.configuration

        #expect(configuration.destination(on: .leading, for: "a") == a)
        #expect(configuration.destination(on: .leading, for: "b") == b)
        #expect(configuration.destination(on: .leading, for: "c") == nil)
        #expect(configuration.destination(on: .leading) == nil)
        #expect(a.settingsLabel == "Projetos · trabalho@okamiops.com")
        #expect(SwipeAction.moveToDestination.command(
            for: aMessage, destination: configuration.destination(on: .leading, for: aMessage.accountID)
        ) == .moveGmailMessage(messageID: "a1", from: gmailInbox, to: gmailLabel))
        #expect(SwipeAction.moveToDestination.command(
            for: bMessage, destination: configuration.destination(on: .leading, for: bMessage.accountID)
        ) == .placeMessage(messageID: "b1", folder: imapFolder, mode: .move))
        #expect(SwipeAction.moveToDestination.command(
            for: otherMessage, destination: configuration.destination(on: .leading, for: otherMessage.accountID)
        ) == nil)

        let reopened = SwipeSettingsStore(defaults: suite)
        #expect(reopened.configuration.destinations(on: .leading) == ["a": a, "b": b])
        suite.removePersistentDomain(forName: name)
    }

    @Test("Destino global legado migra somente para a conta que ele contém")
    @MainActor
    func legacyGlobalDestinationMigratesToItsOwningAccount() throws {
        let name = "okamiuni.swipe.test.destination-legacy-migration"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)

        let folder = MailFolder(
            id: "a/Projetos", accountID: "a", serverName: "Projetos",
            displayName: "Projetos", role: .other
        )
        let legacy = SwipeMoveDestination(imapFolder: folder)
        suite.set(
            [SwipeAction.archive.rawValue, SwipeAction.moveToDestination.rawValue],
            forKey: "okamiuni.swipe.leading"
        )
        suite.set(
            try JSONEncoder().encode(legacy),
            forKey: "okamiuni.swipe.leading.destination"
        )

        let store = SwipeSettingsStore(defaults: suite)
        #expect(store.configuration.destination(on: .leading, for: "a") == legacy)
        #expect(store.configuration.destination(on: .leading, for: "b") == nil)
        #expect(store.configuration.leading == [.archive, .moveToDestination])
        #expect(suite.data(forKey: "okamiuni.swipe.leading.destination") == nil)
        #expect(suite.data(forKey: "okamiuni.swipe.leading.destinations") != nil)
        suite.removePersistentDomain(forName: name)
    }

    @Test("Destino de gesto não é salvo silenciosamente quando o lado está cheio")
    @MainActor
    func moveDestinationRequiresAvailableSlot() throws {
        let name = "okamiuni.swipe.test.destination-full"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        let folder = MailFolder(
            id: "zoho/INBOX.Clientes", accountID: "zoho", serverName: "INBOX.Clientes",
            displayName: "Clientes", role: .other
        )
        let store = SwipeSettingsStore(defaults: suite)
        store.setActions([.archive, .toggleRead, .later], on: .leading)

        #expect(!store.setMoveDestination(SwipeMoveDestination(imapFolder: folder), on: .leading))
        #expect(store.configuration.leading == [.archive, .toggleRead, .later])
        #expect(store.configuration.destination(on: .leading) == nil)
        suite.removePersistentDomain(forName: name)
    }

    /// O arraste apaga **para a Lixeira**, e nunca de vez: jogar fora sem volta
    /// não pode ficar a um gesto de distância. E o caminho de volta é a caixa
    /// de onde ela veio, como em toda ação de triagem.
    @Test("a coluna de apagar leva à Lixeira, com volta para a caixa de origem")
    func trashColumnGoesToTheTrashAndBack() {
        let vinda = message(bucket: .later)
        #expect(SwipeAction.trash.command(for: vinda) == .move(messageID: "m1", to: .trash))
        #expect(SwipeAction.trash.undo(for: vinda) == .move(messageID: "m1", to: .later))
        #expect(SwipeAction.trash.receiptTitle(for: vinda) == "Movida para a Lixeira")

        // Já na Lixeira ela não faria nada, e o botão diz por quê.
        let dentro = message(bucket: .trash)
        #expect(SwipeAction.trash.isNoOp(for: dentro))
        #expect(SwipeAction.trash.command(for: dentro) == nil)
        #expect(SwipeAction.trash.help(for: dentro) == "Esta mensagem já está em Lixeira")
    }

    /// Como a de leitura: uma ação com dois rótulos, e nunca muda.
    @Test("a coluna da estrela diz o contrário do estado, e sempre faz algo")
    func flagColumnMirrorsTheState() {
        let semEstrela = message()
        #expect(!SwipeAction.toggleFlag.isNoOp(for: semEstrela))
        #expect(SwipeAction.toggleFlag.title(for: semEstrela) == "Sinalizar")
        #expect(SwipeAction.toggleFlag.command(for: semEstrela)
            == .setFlagged(messageID: "m1", isFlagged: true))
        #expect(SwipeAction.toggleFlag.receiptTitle(for: semEstrela) == "Sinalizada")

        let comEstrela = message(isFlagged: true)
        #expect(SwipeAction.toggleFlag.title(for: comEstrela) == "Tirar")
        #expect(SwipeAction.toggleFlag.command(for: comEstrela)
            == .setFlagged(messageID: "m1", isFlagged: false))
        // O caminho de volta é o estado **anterior**, não o negado do atual.
        #expect(SwipeAction.toggleFlag.undo(for: comEstrela)
            == .setFlagged(messageID: "m1", isFlagged: true))
    }

    /// Arquivar e apagar tiram a mensagem da triagem inteira; adiar, trazer
    /// para hoje, ler e sinalizar são movimentos dentro dela. Um painel todo
    /// forte não teria hierarquia nenhuma.
    @Test("só as duas que tiram a mensagem da lista pintam forte")
    func onlyTheRemovingActionsAreStrong() {
        #expect(SwipeAction.allCases.filter { $0.tint == .strong } == [.archive, .trash])
    }

    /// Os números que os testes de fronteira citam. Se algum mudar, o teste
    /// que o cita muda junto — de propósito: fronteira só vale cravada.
    @Test("os limiares do gesto são os que o desenho promete")
    func metrics() {
        #expect(SwipeMetrics.engage == 12)
        #expect(SwipeMetrics.dominance == 1.5)
        #expect(SwipeMetrics.actionWidth == 84)
        #expect(SwipeMetrics.openThreshold == 42)
        #expect(SwipeMetrics.panelWidth(actions: 2) == 168)
        #expect(SwipeMetrics.commitFraction == 0.75)
        #expect(SwipeMetrics.commitMargin == 90)
        #expect(SwipeMetrics.resistance == 0.125)
        #expect(SwipeMetrics.referenceRowWidth == 370)
        // Na lista de referência com o padrão de duas colunas quem manda é a
        // fração: 75% de 370. O piso (168 + 90 = 258) fica abaixo.
        #expect(SwipeMetrics.commitThreshold(actions: 2) == 277.5)
        // Três colunas empurram o limiar de disparo junto. Um número cravado
        // ficaria **abaixo** do painel, e a linha dispararia antes de abrir.
        #expect(SwipeMetrics.commitThreshold(actions: 3) == 342)
    }

    // MARK: - O limiar de disparo segue a largura da linha

    /// O defeito que o dono do projeto relatou: com **mouse**, o arraste nunca
    /// parava no painel aberto, ele atravessava e disparava. O limiar era
    /// absoluto — 228pt numa lista de 370, 62% do caminho, com o painel
    /// descansando em 168 (45%). Sobravam 60pt entre "aberto" e "disparou".
    ///
    /// Agora ele é três quartos da linha: 277,5 a 370. Entre o painel e o
    /// disparo há 109,5pt de arraste, com a resistência a um oitavo — que é o
    /// que faz o ponto de descanso ser um lugar onde o gesto para.
    @Test("o limiar de disparo acompanha a largura da linha")
    func commitFollowsRowWidth() {
        #expect(SwipeMetrics.commitThreshold(actions: 2, rowWidth: 420) == 315)
        #expect(SwipeMetrics.commitThreshold(actions: 2, rowWidth: 370) == 277.5)
        // Na lista mais estreita que `PaneLayout` concede, 75% dariam 240 —
        // 72pt além do painel, o mesmo aperto de antes. O piso assume.
        #expect(SwipeMetrics.commitThreshold(actions: 2, rowWidth: 320) == 258)
    }

    /// A folga entre o painel aberto e o disparo, nas larguras reais. Ela é o
    /// número que o relato do dono do projeto media: 60pt não bastavam para um
    /// mouse.
    @Test("entre o painel aberto e o disparo sobra sempre a margem inteira")
    func restingBandIsAlwaysGenerous() {
        for width in [CGFloat(320), 370, 420] {
            let gap = SwipeMetrics.commitThreshold(actions: 2, rowWidth: width)
                - SwipeMetrics.panelWidth(actions: 2)
            #expect(gap >= SwipeMetrics.commitMargin,
                    "a \(width) sobram só \(gap)pt entre aberto e disparo")
        }
    }

    /// Numa lista larga o piso não pode virar o limiar: seria voltar ao número
    /// absoluto que causou o defeito.
    @Test("a fração manda na lista larga; o piso, na estreita e nas três colunas")
    func fractionAndFloorEachTakeTheirTurn() {
        // Larga: 75% de 420 = 315 > 258.
        #expect(SwipeMetrics.commitThreshold(actions: 2, rowWidth: 420)
                == SwipeMetrics.commitFraction * 420)
        // Estreita: o piso.
        #expect(SwipeMetrics.commitThreshold(actions: 2, rowWidth: 320)
                == SwipeMetrics.panelWidth(actions: 2) + SwipeMetrics.commitMargin)
        // Três colunas na largura de referência: o piso de novo, porque 277,5
        // ficaria a 25pt do fim de um painel de 252.
        #expect(SwipeMetrics.commitThreshold(actions: 3, rowWidth: 370)
                == SwipeMetrics.panelWidth(actions: 3) + SwipeMetrics.commitMargin)
    }

    /// O disparo por arraste longo fica **além** de 70% da linha em qualquer
    /// largura da faixa — a referência do brief, medida e não prometida.
    @Test("em toda a faixa de largura, o disparo só vem além de 70% da linha")
    func commitIsAlwaysPastSeventyPercent() {
        for width in [CGFloat(320), 340, 370, 400, 420] {
            let threshold = SwipeMetrics.commitThreshold(actions: 2, rowWidth: width)
            #expect(threshold >= 0.7 * width,
                    "a \(width) o disparo vem a \(threshold), aquém de 70%")
        }
    }

    // MARK: - Fronteira 1: o gesto ainda é clique

    @Test("um ponto antes do engate, o gesto não é nosso")
    func beforeEngage() {
        let side = SwipeGesture.side(translation: CGSize(width: 11.9, height: 0))
        #expect(side == nil)
    }

    @Test("no engate, o lado aparece")
    func atEngage() {
        let side = SwipeGesture.side(translation: CGSize(width: 12, height: 0))
        #expect(side == .leading)
    }

    @Test("o mesmo engate vale para o outro lado")
    func atEngageTrailing() {
        #expect(SwipeGesture.side(translation: CGSize(width: -11.9, height: 0)) == nil)
        #expect(SwipeGesture.side(translation: CGSize(width: -12, height: 0)) == .trailing)
    }

    /// Clique e duplo clique não andam. Se o engate voltar a 0, este passa a
    /// devolver um lado e o gesto canibaliza a seleção.
    @Test("clique parado nunca vira arraste")
    func aClickIsNotADrag() {
        #expect(SwipeGesture.side(translation: .zero) == nil)
    }

    // MARK: - Fronteira 2: a horizontal precisa dominar a vertical

    @Test("na razão exata, a horizontal ganha")
    func atDominance() {
        // 30 >= 1.5 × 20 → é arraste lateral.
        let side = SwipeGesture.side(translation: CGSize(width: 30, height: 20))
        #expect(side == .leading)
    }

    @Test("um décimo de ponto a mais de vertical e o gesto é da rolagem")
    func pastDominance() {
        // 30 < 1.5 × 20.1 = 30.15 → rolagem.
        let side = SwipeGesture.side(translation: CGSize(width: 30, height: 20.1))
        #expect(side == nil)
    }

    @Test("um gesto que começa vertical é rolagem, por mais longo que seja")
    func verticalIsScroll() {
        #expect(SwipeGesture.side(translation: CGSize(width: 20, height: 300)) == nil)
        #expect(SwipeGesture.side(translation: CGSize(width: -20, height: -300)) == nil)
    }

    /// Uma vez lateral, sempre lateral até soltar: baixar a mão no meio do
    /// caminho não devolve a linha para a rolagem com o painel meio aberto.
    @Test("o lado travado sobrevive a uma guinada vertical")
    func lockedSideSurvives() {
        let side = SwipeGesture.side(
            translation: CGSize(width: 20, height: 300), locked: .leading
        )
        #expect(side == .leading)
    }

    @Test("lado sem ação nenhuma não engata")
    func emptySideNeverEngages() {
        let config = SwipeConfiguration(leading: [], trailing: [.later])
        #expect(SwipeGesture.side(translation: CGSize(width: 200, height: 0),
                                  configuration: config) == nil)
        #expect(SwipeGesture.side(translation: CGSize(width: -200, height: 0),
                                  configuration: config) == .trailing)
    }

    // MARK: - Fronteira 3: soltar devolve a linha, ou a deixa aberta

    @Test("um ponto antes do limiar de abertura, a linha volta ao lugar")
    func beforeOpen() {
        let release = SwipeGesture.release(
            translation: CGSize(width: 41.9, height: 0), message: message()
        )
        #expect(release == .closed)
    }

    @Test("no limiar de abertura, a linha fica aberta")
    func atOpen() {
        let release = SwipeGesture.release(
            translation: CGSize(width: 42, height: 0), message: message()
        )
        #expect(release == .open(.leading))
    }

    // MARK: - Fronteira 4: o arraste longo dispara sozinho

    @Test("um ponto antes do disparo, soltar só deixa aberta")
    func beforeCommit() {
        let target = message()
        let short = CGSize(width: 277.4, height: 0)
        #expect(SwipeGesture.resolve(translation: short, message: target).willFire == false)
        #expect(SwipeGesture.release(translation: short, message: target) == .open(.leading))
    }

    @Test("no limiar do disparo, a primeira ação do lado vai sozinha")
    func atCommit() {
        let target = message()
        let long = CGSize(width: 277.5, height: 0)
        #expect(SwipeGesture.resolve(translation: long, message: target).willFire)
        #expect(SwipeGesture.release(translation: long, message: target)
                == .fire(.archive, .leading))
    }

    @Test("o mesmo limiar, do outro lado, dispara a primeira do outro lado")
    func atCommitTrailing() {
        let target = message(bucket: .today)
        #expect(SwipeGesture.release(translation: CGSize(width: -277.4, height: 0),
                                     message: target) == .open(.trailing))
        #expect(SwipeGesture.release(translation: CGSize(width: -277.5, height: 0),
                                     message: target) == .fire(.later, .trailing))
    }

    /// A mesma fronteira, uma linha mais estreita: o mesmo deslocamento que
    /// dispara a 370 ainda só abre — não, ao contrário: a 320 o limiar é
    /// **menor** (258, o piso), então quem dispara antes é a lista estreita.
    /// O que não pode acontecer é o limiar ignorar a largura.
    @Test("a fronteira do disparo se move com a largura passada")
    func commitBoundaryMovesWithWidth() {
        let target = message()
        // A 420 o limiar é 315: 277,5 já não dispara mais.
        #expect(SwipeGesture.release(translation: CGSize(width: 277.5, height: 0),
                                     message: target, rowWidth: 420) == .open(.leading))
        #expect(SwipeGesture.release(translation: CGSize(width: 314.9, height: 0),
                                     message: target, rowWidth: 420) == .open(.leading))
        #expect(SwipeGesture.release(translation: CGSize(width: 315, height: 0),
                                     message: target, rowWidth: 420)
                == .fire(.archive, .leading))
        // A 320 o limiar é o piso, 258.
        #expect(SwipeGesture.release(translation: CGSize(width: 257.9, height: 0),
                                     message: target, rowWidth: 320) == .open(.leading))
        #expect(SwipeGesture.release(translation: CGSize(width: 258, height: 0),
                                     message: target, rowWidth: 320)
                == .fire(.archive, .leading))
    }

    /// O ponto de descanso aberto tem de ser **alcançável e estável**: entre o
    /// limiar de abertura e o de disparo, soltar deixa a linha aberta em
    /// qualquer ponto. É essa faixa que o dono do projeto não conseguia achar.
    @Test("a faixa de descanso aberto vai do painel meio revelado até o disparo")
    func theOpenRestingBandIsWide() {
        let target = message()
        for magnitude in [CGFloat(42), 84, 168, 200, 240, 277.4] {
            #expect(
                SwipeGesture.release(
                    translation: CGSize(width: magnitude, height: 0), message: target
                ) == .open(.leading),
                "soltar a \(magnitude) não deixou a linha aberta"
            )
        }
    }

    /// Com três colunas o limiar sobe junto, e o mesmo deslocamento que
    /// disparava com duas passa a só abrir.
    @Test("com três colunas o disparo se afasta")
    func commitFollowsPanel() {
        let config = SwipeConfiguration(leading: [.archive, .toggleRead, .later], trailing: [])
        let target = message()
        #expect(SwipeGesture.release(translation: CGSize(width: 277.5, height: 0),
                                     configuration: config, message: target)
                == .open(.leading))
        #expect(SwipeGesture.release(translation: CGSize(width: 341.9, height: 0),
                                     configuration: config, message: target)
                == .open(.leading))
        #expect(SwipeGesture.release(translation: CGSize(width: 342, height: 0),
                                     configuration: config, message: target)
                == .fire(.archive, .leading))
    }

    // MARK: - Qual ação está armada

    @Test("a armada é a primeira do lado")
    func armedIsTheFirst() {
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: 100, height: 0), message: message()
        )
        #expect(resolution.armed == .archive)
        #expect(resolution.side == .leading)
    }

    /// `MailStore.move` recusa mover para a caixa em que a mensagem já está.
    /// Armar essa ação faria o arraste longo não fazer nada — e o gesto mais
    /// decidido do app seria o único sem efeito.
    @Test("a ação que não faria nada não arma; a seguinte assume")
    func noOpNeverArms() {
        // Mensagem já em "Depois": `.later` é muda, `.today` assume.
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: -100, height: 0), message: message(bucket: .later)
        )
        #expect(resolution.armed == .today)
    }

    @Test("um lado inteiramente mudo não dispara nem no arraste mais longo")
    func silentSideNeverFires() {
        let config = SwipeConfiguration(leading: [], trailing: [.today])
        let target = message(bucket: .today)
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: -400, height: 0), configuration: config, message: target
        )
        #expect(resolution.armed == nil)
        #expect(resolution.willFire == false)
        #expect(SwipeGesture.release(translation: CGSize(width: -400, height: 0),
                                     configuration: config, message: target)
                == .open(.trailing))
    }

    @Test("a de leitura nunca é muda: ela sempre tem o outro estado para ir")
    func readToggleIsAlwaysLive() {
        #expect(SwipeAction.toggleRead.isNoOp(for: message(isRead: false)) == false)
        #expect(SwipeAction.toggleRead.isNoOp(for: message(isRead: true)) == false)
    }

    // MARK: - Quanto revelar

    @Test("dentro do painel, revela o que o dedo andou")
    func revealFollowsTheFinger() {
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: 100, height: 0), message: message()
        )
        #expect(resolution.offset == 100)
    }

    @Test("no fim do painel, revela o painel inteiro")
    func revealStopsAtThePanel() {
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: 168, height: 0), message: message()
        )
        #expect(resolution.offset == 168)
    }

    /// Sem resistência, o arraste até o limiar de disparo jogaria a linha 228pt
    /// para o lado numa lista de 370 — quase toda a lista virava painel.
    @Test("além do painel, a linha resiste")
    func revealResistsPastThePanel() {
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: 296, height: 0), message: message()
        )
        // 168 + (296 − 168) × 0.125 = 184
        #expect(resolution.offset == 184)
        #expect(resolution.offset < 296)
    }

    /// A resistência tem de ser **parede**, não freio. Com 0,35 (o valor de
    /// antes) os 109,5pt entre o painel e o disparo viravam 38pt de painel
    /// andando — a linha continuava escorregando e o gesto não tinha onde
    /// parar. Com um oitavo são 13,7pt: o painel praticamente trava no lugar
    /// de descanso, e o que muda de lá em diante é a cor, não a posição.
    @Test("a resistência além do painel é parede: oito de mão para um de painel")
    func resistanceIsAWall() {
        let target = message()
        let panel = SwipeMetrics.panelWidth(actions: 2)
        let atCommit = SwipeGesture.resolve(
            translation: CGSize(width: SwipeMetrics.commitThreshold(actions: 2), height: 0),
            message: target
        )
        let travelled = atCommit.offset - panel
        #expect(travelled > 0, "o painel não anda nada além do fim — isso é trava, não parede")
        #expect(travelled < 16,
                "do painel ao disparo o painel andou \(travelled)pt — é freio, não parede")

        // E oito pontos de mão viram um de painel, medido.
        let a = SwipeGesture.resolve(translation: CGSize(width: 200, height: 0), message: target)
        let b = SwipeGesture.resolve(translation: CGSize(width: 208, height: 0), message: target)
        #expect(b.offset - a.offset == 1)
    }

    @Test("o painel do outro lado revela para o negativo")
    func trailingOffsetIsNegative() {
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: -100, height: 0), message: message()
        )
        #expect(resolution.offset == -100)
        #expect(resolution.side == .trailing)
    }

    /// Trocar de painel sob o dedo é como se perde a noção do que vai
    /// disparar. Voltar atrás **fecha**.
    @Test("voltar atrás fecha, não abre o painel oposto")
    func crossingBackCloses() {
        let resolution = SwipeGesture.resolve(
            translation: CGSize(width: -60, height: 0), locked: .leading, message: message()
        )
        #expect(resolution.side == .leading)
        #expect(resolution.offset == 0)
        #expect(resolution.isOpen == false)
        #expect(SwipeGesture.release(translation: CGSize(width: -60, height: 0),
                                     locked: .leading, message: message()) == .closed)
    }

    // MARK: - O que a ação manda fazer

    @Test("arquivar move para arquivado e volta para a caixa de origem")
    func archiveCommands() {
        let target = message(bucket: .today)
        #expect(SwipeAction.archive.command(for: target)
                == .move(messageID: "m1", to: .archived))
        #expect(SwipeAction.archive.undo(for: target)
                == .move(messageID: "m1", to: .today))
    }

    /// O caminho de volta sai da mensagem **antes** da mudança. Uma mensagem
    /// que veio de "Depois" volta para "Depois", não para "Hoje" — se o
    /// desfazer passar a adivinhar, este teste cai.
    @Test("desfazer devolve à caixa de onde a mensagem veio, não à padrão")
    func undoRestoresTheOriginalBucket() {
        let target = message(bucket: .later)
        #expect(SwipeAction.archive.undo(for: target)
                == .move(messageID: "m1", to: .later))
    }

    @Test("a de leitura inverte e desinverte")
    func readToggleCommands() {
        let unread = message(isRead: false)
        #expect(SwipeAction.toggleRead.command(for: unread)
                == .setRead(messageID: "m1", isRead: true))
        #expect(SwipeAction.toggleRead.undo(for: unread)
                == .setRead(messageID: "m1", isRead: false))

        let read = message(isRead: true)
        #expect(SwipeAction.toggleRead.command(for: read)
                == .setRead(messageID: "m1", isRead: false))
    }

    @Test("ação muda não manda fazer nada, nem desfazer")
    func noOpHasNoCommand() {
        let target = message(bucket: .today)
        #expect(SwipeAction.today.command(for: target) == nil)
        #expect(SwipeAction.today.undo(for: target) == nil)
    }

    @Test("o rótulo da leitura é o contrário do estado corrente")
    func readToggleLabel() {
        #expect(SwipeAction.toggleRead.title(for: message(isRead: true)) == "Não lida")
        #expect(SwipeAction.toggleRead.title(for: message(isRead: false)) == "Lida")
    }

    @Test("o help de uma ação muda diz por que ela está calada")
    func noOpHelpExplains() {
        #expect(SwipeAction.today.help(for: message(bucket: .today))
                == "Esta mensagem já está em Hoje")
        #expect(SwipeAction.today.help(for: message(bucket: .later)) == "Mover para Hoje")
    }

    // MARK: - Recibo

    @Test("o recibo copia o idioma da faixa de resposta")
    func receiptReadsLikeTheReplyBand() throws {
        let target = message(bucket: .today)
        let receipt = try #require(
            SwipeReceipt.of(.archive, message: target, stamp: "14:32")
        )
        #expect(receipt.note == "Arquivada — Marina Duarte · 14:32")
        #expect(receipt.undo == .move(messageID: "m1", to: .today))
        #expect(receipt.messageID == "m1")
    }

    @Test("sem nome, o recibo cai no endereço")
    func receiptFallsBackToAddress() {
        let target = message(name: "", address: "ninguem@exemplo.com")
        #expect(SwipeReceipt.note(.archive, message: target, stamp: "09:00")
                == "Arquivada — ninguem@exemplo.com · 09:00")
    }

    @Test("a frase do recibo fala do estado anterior")
    func receiptSpeaksOfThePastState() {
        #expect(SwipeAction.toggleRead.receiptTitle(for: message(isRead: false))
                == "Marcada como lida")
        #expect(SwipeAction.toggleRead.receiptTitle(for: message(isRead: true))
                == "Marcada como não lida")
        #expect(SwipeAction.later.receiptTitle(for: message()) == "Adiada para depois")
        #expect(SwipeAction.today.receiptTitle(for: message(bucket: .later))
                == "Trazida para hoje")
    }

    /// Faixa dizendo "Arquivada" sem nada ter sido arquivado é o botão mudo
    /// com outra roupa.
    @Test("ação muda não gera recibo")
    func noReceiptForANoOp() {
        #expect(SwipeReceipt.of(.today, message: message(bucket: .today), stamp: "14:32") == nil)
    }

    // MARK: - Configuração

    @Test("o padrão é duas de cada lado, como foi pedido")
    func defaultHasTwoPerSide() {
        #expect(SwipeConfiguration.default.leading == [.archive, .toggleRead])
        #expect(SwipeConfiguration.default.trailing == [.later, .today])
        #expect(SwipeConfiguration.default.actions(on: .leading).count == 2)
        #expect(SwipeConfiguration.default.actions(on: .trailing).count == 2)
    }

    @Test("repetição some e a ordem escolhida fica")
    func configurationDeduplicates() {
        let config = SwipeConfiguration(leading: [.today, .archive, .today], trailing: [])
        #expect(config.leading == [.today, .archive])
    }

    @Test("mais que o teto por lado não entra")
    func configurationCaps() {
        let config = SwipeConfiguration(
            leading: [.archive, .toggleRead, .later, .today], trailing: []
        )
        #expect(config.leading.count == SwipeConfiguration.maxPerSide)
        #expect(config.leading == [.archive, .toggleRead, .later])
    }

    // MARK: - Persistência

    @MainActor
    @Test("sem nada gravado, vale o padrão")
    func storeDefaults() throws {
        let suite = try #require(UserDefaults(suiteName: "okamiuni.swipe.test.defaults"))
        suite.removePersistentDomain(forName: "okamiuni.swipe.test.defaults")
        let store = SwipeSettingsStore(defaults: suite)
        #expect(store.configuration == .default)
    }

    @MainActor
    @Test("a escolha sobrevive ao relançamento, como o tema")
    func storePersists() throws {
        let name = "okamiuni.swipe.test.persist"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)

        let first = SwipeSettingsStore(defaults: suite)
        first.setActions([.today, .archive], on: .leading)

        let second = SwipeSettingsStore(defaults: suite)
        #expect(second.configuration.leading == [.today, .archive])
        // O lado que ninguém mexeu continua no padrão.
        #expect(second.configuration.trailing == SwipeConfiguration.default.trailing)

        suite.removePersistentDomain(forName: name)
    }

    /// Desligar um lado é escolha, e tem de sobreviver ao relançamento. Se a
    /// leitura passar a olhar o tamanho da lista em vez da existência da
    /// chave, este lado volta sozinho ao padrão.
    @MainActor
    @Test("um lado desligado de propósito continua desligado")
    func storeKeepsAnEmptySide() throws {
        let name = "okamiuni.swipe.test.empty"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)

        SwipeSettingsStore(defaults: suite).setActions([], on: .trailing)

        let reopened = SwipeSettingsStore(defaults: suite)
        #expect(reopened.configuration.trailing.isEmpty)
        #expect(reopened.configuration.leading == SwipeConfiguration.default.leading)

        suite.removePersistentDomain(forName: name)
    }

    @MainActor
    @Test("conteúdo que não decodifica em nada cai no padrão")
    func storeSurvivesGarbage() throws {
        let name = "okamiuni.swipe.test.garbage"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        suite.set(["nao-existe", "tambem-nao"], forKey: "okamiuni.swipe.leading")

        let store = SwipeSettingsStore(defaults: suite)
        #expect(store.configuration.leading == SwipeConfiguration.default.leading)

        suite.removePersistentDomain(forName: name)
    }

    @MainActor
    @Test("voltar ao padrão apaga a escolha, não a regrava")
    func storeReset() throws {
        let name = "okamiuni.swipe.test.reset"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)

        let store = SwipeSettingsStore(defaults: suite)
        store.setActions([], on: .leading)
        store.resetToDefault()

        #expect(store.configuration == .default)
        #expect(suite.array(forKey: "okamiuni.swipe.leading") == nil)
        #expect(SwipeSettingsStore(defaults: suite).configuration == .default)

        suite.removePersistentDomain(forName: name)
    }
}
