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
        bucket: TriageBucket = .today,
        isRead: Bool = false,
        name: String = "Marina Duarte",
        address: String = "marina@clientepremium.com"
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: name, address: address),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: bucket, isRead: isRead,
            summary: nil, detectedEvent: nil
        )
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
        #expect(SwipeMetrics.commitThreshold(actions: 2) == 228)
        // Três colunas empurram o limiar de disparo junto. Um número cravado
        // ficaria **abaixo** do painel, e a linha dispararia antes de abrir.
        #expect(SwipeMetrics.commitThreshold(actions: 3) == 312)
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
        let short = CGSize(width: 227.9, height: 0)
        #expect(SwipeGesture.resolve(translation: short, message: target).willFire == false)
        #expect(SwipeGesture.release(translation: short, message: target) == .open(.leading))
    }

    @Test("no limiar do disparo, a primeira ação do lado vai sozinha")
    func atCommit() {
        let target = message()
        let long = CGSize(width: 228, height: 0)
        #expect(SwipeGesture.resolve(translation: long, message: target).willFire)
        #expect(SwipeGesture.release(translation: long, message: target)
                == .fire(.archive, .leading))
    }

    @Test("o mesmo limiar, do outro lado, dispara a primeira do outro lado")
    func atCommitTrailing() {
        let target = message(bucket: .today)
        #expect(SwipeGesture.release(translation: CGSize(width: -227.9, height: 0),
                                     message: target) == .open(.trailing))
        #expect(SwipeGesture.release(translation: CGSize(width: -228, height: 0),
                                     message: target) == .fire(.later, .trailing))
    }

    /// Com três colunas o limiar sobe junto, e o mesmo deslocamento que
    /// disparava com duas passa a só abrir.
    @Test("com três colunas o disparo se afasta")
    func commitFollowsPanel() {
        let config = SwipeConfiguration(leading: [.archive, .toggleRead, .later], trailing: [])
        let target = message()
        #expect(SwipeGesture.release(translation: CGSize(width: 228, height: 0),
                                     configuration: config, message: target)
                == .open(.leading))
        #expect(SwipeGesture.release(translation: CGSize(width: 312, height: 0),
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
            translation: CGSize(width: 268, height: 0), message: message()
        )
        // 168 + (268 − 168) × 0.35 = 203
        #expect(resolution.offset == 203)
        #expect(resolution.offset < 268)
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
