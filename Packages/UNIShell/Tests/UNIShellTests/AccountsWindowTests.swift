import AppKit
import Foundation
import NIOPosix
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

@Suite("A janela de Contas")
@MainActor
struct AccountsWindowTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }

    private func status(
        state: Account.State = .ativa,
        erro: SyncError? = nil,
        progresso: LoadProgress? = nil,
        sincronizada: Date? = Date(timeIntervalSince1970: 1_799_996_400),
        mensagens: Int = 1_284,
        aguardando: Int = 0,
        fila: SyncError? = nil
    ) -> AccountStatus {
        AccountStatus(
            accountID: "conta-a", address: "contato@meusite.com", hostMark: "meusite",
            state: state, messageCount: mensagens, lastSyncedAt: sincronizada,
            error: erro, progress: progresso, pendingOperations: aguardando,
            queueError: fila
        )
    }

    // MARK: A fila parada

    /// **O defeito relatado.** A conta do dono tinha 3 operações `falhou` e 2
    /// `pendente` na `outbox`, a fila parada desde as 09:21 — e a linha dizia
    /// "Sincronizada às 00:59 · 48 mensagens · 5 aguardando". Saudável. Sem a
    /// causa, sem a parada, sem saída.
    ///
    /// O número sozinho não denuncia nada: "5 aguardando" é o que uma fila
    /// andando também mostra. O que falta é a palavra que separa uma da outra.
    ///
    /// MUTAÇÃO QUE ISTO PEGA: tirar `queueError` de `AccountsCopy.fila`. O
    /// texto volta a ser o da conta saudável e as três primeiras afirmações
    /// caem.
    @Test("A conta com a fila parada diz que está parada, por quê, e oferece tentar de novo")
    func filaParadaApareceNaLinha() {
        let parada = SyncError.autorizacaoRevogada
        let texto = AccountsCopy.status(
            status(aguardando: 5, fila: parada), now: agora, calendar: calendario
        )
        #expect(texto.contains("5 aguardando"))
        #expect(texto.contains("parada:"))
        #expect(texto.contains(parada.mensagem))
        // O que a conta já dizia continua dito: a fila parada não é o único
        // fato da linha.
        #expect(texto.hasPrefix("Sincronizada às "))
        // E a linha lê como quebrada — é o realce que a janela pinta.
        #expect(AccountsCopy.isFailing(status(aguardando: 5, fila: parada)))
        // A saída: uma ação para a fila, ao lado do remover. O ciclo está bem,
        // então não há ação de ciclo nenhuma aqui.
        #expect(AccountsCopy.actions(for: status(aguardando: 5, fila: parada))
            == [.retryQueue(parada), .remove])
    }

    /// **"Tentar de novo" da fila religa a fila — não recarrega a conta.**
    ///
    /// As duas ações do erro de ciclo (`reconnect`, `retry`) caem em
    /// `loadInitial`, que baixa mensagens. A fila parada não precisa de carga
    /// nenhuma: ela precisa que a trava saia e as linhas `falhou` voltem para
    /// `pendente` — `OutboxExecutor.retryAfterPermanentFailure`. Mandá-la para
    /// `onRetry` refaria a carga inicial inteira e deixaria a fila parada
    /// exatamente onde estava.
    @Test("A ação da fila parada não cai no mesmo caminho do erro de ciclo")
    func filaParadaTemCaminhoProprio() {
        var reconectou = 0
        var tentou = 0
        var religou: [String] = []
        let lista = AccountsList(
            statuses: [],
            onReconnect: { _ in reconectou += 1 },
            onRetry: { _ in tentou += 1 },
            onRetryQueue: { id in religou.append(id) },
            onRemove: { _ in }
        )
        lista.execute(.retryQueue(.autorizacaoRevogada), on: "conta-a")
        #expect(religou == ["conta-a"])
        #expect(reconectou == 0, "a fila parada chamou onReconnect")
        #expect(tentou == 0, "a fila parada chamou onRetry")
    }

    // MARK: O selo da fila de saída

    /// "n aguardando" na linha da conta.
    ///
    /// Ele mora na linha de estado que já existe, e não numa superfície nova:
    /// o lugar onde a pessoa já olha para saber como a conta está é aquela
    /// linha, e um segundo selo ao lado diria a mesma coisa duas vezes.
    @Test("A fila de saída aparece como «n aguardando», e some quando está vazia")
    func seloDaFila() {
        // Fila vazia é o normal: "0 aguardando" em toda conta, o dia inteiro,
        // treinaria a pessoa a não ler a linha.
        #expect(!AccountsCopy.status(status(), now: agora, calendar: calendario).contains("aguardando"))

        let comFila = AccountsCopy.status(status(aguardando: 3), now: agora, calendar: calendario)
        #expect(comFila.contains("3 aguardando"))
        // E sem perder o que a linha já dizia.
        #expect(comFila.contains("1.284 mensagens"))
        #expect(comFila.hasPrefix("Sincronizada às "))

        // Milhar com separador, como a contagem de mensagens ao lado: uma fila
        // de 1284 operações escrita "1284" ao lado de "1.284 mensagens" leria
        // como dois números de tipos diferentes.
        #expect(AccountsCopy.status(status(aguardando: 1_284), now: agora, calendar: calendario)
            .contains("1.284 aguardando"))
    }

    /// **Fila parada é exatamente quando o número importa**: ele diz quanta
    /// coisa está esperando o "Tentar de novo" que a linha oferece ao lado.
    /// A frase do erro toma a frente da linha, e o selo continua lá.
    @Test("A conta parada mostra o erro E quantas operações esperam por ele")
    func seloSobreviveAoErro() {
        let texto = AccountsCopy.status(
            status(erro: .rede("A conexão caiu."), aguardando: 2),
            now: agora, calendar: calendario
        )
        #expect(texto.hasPrefix(SyncError.rede("A conexão caiu.").mensagem))
        #expect(texto.contains("2 aguardando"))
        // E a saída oferecida continua sendo a do erro — o selo é informação,
        // não uma ação a mais.
        #expect(AccountsCopy.actions(for: status(erro: .rede("A conexão caiu."), aguardando: 2))
            == [.retry(.rede("A conexão caiu.")), .remove])
    }

    // MARK: O texto — puro, e é onde estão as decisões

    @Test("Conta ativa diz quando sincronizou, no relógio de quem lê")
    func textoAtiva() {
        let texto = AccountsCopy.status(status(), now: agora, calendar: calendario)
        #expect(texto.hasPrefix("Sincronizada às "))
        #expect(texto.contains("1.284 mensagens"))
    }

    @Test("Conta que nunca sincronizou não inventa data")
    func textoNuncaSincronizou() {
        let texto = AccountsCopy.status(
            status(sincronizada: nil, mensagens: 0), now: agora, calendar: calendario
        )
        #expect(texto.contains("Ainda não sincronizada"))
        #expect(!texto.contains("às"))
    }

    @Test("Carregando mostra o progresso em porcentagem, não uma barra muda")
    func textoCarregando() {
        let texto = AccountsCopy.status(
            status(state: .carregando, progresso: LoadProgress(accountID: "conta-a", done: 250, total: 1_000)),
            now: agora, calendar: calendario
        )
        #expect(texto.contains("Carregando"))
        #expect(texto.contains("25%"))
    }

    @Test("Carregando sem total conhecido não escreve porcentagem inventada")
    func textoCarregandoSemTotal() {
        let texto = AccountsCopy.status(status(state: .carregando), now: agora, calendar: calendario)
        #expect(texto.contains("Carregando"))
        #expect(!texto.contains("%"))
    }

    @Test("Erro mostra a **causa**, não 'algo deu errado'")
    func textoDeErro() {
        // A regra do projeto: erro nunca engolido. Cada `SyncError` tem uma
        // frase; a janela mostra aquela frase.
        for erro in [SyncError.autenticacao, .rede("tempo esgotado"), .tls("certificado expirado"), .quota] {
            let texto = AccountsCopy.status(status(state: .erroDeAutenticacao, erro: erro), now: agora, calendar: calendario)
            #expect(texto.contains(erro.mensagem), "faltou a causa de \(erro)")
        }
    }

    @Test("Erro de autenticação pede reconectar; erro de rede pede tentar de novo")
    func acaoCombinaComACausa() {
        // Duas ações diferentes porque são dois problemas diferentes.
        // "Reconectar" para quem só perdeu o wi-fi manda a pessoa refazer o
        // consentimento à toa.
        #expect(AccountsCopy.action(for: .autenticacao) == "Reconectar")
        #expect(AccountsCopy.action(for: .autorizacaoRevogada) == "Reconectar")
        #expect(AccountsCopy.action(for: .semClientID) == "Ver o roteiro")
        #expect(AccountsCopy.action(for: .rede("x")) == "Tentar de novo")
        #expect(AccountsCopy.action(for: .tls("x")) == "Tentar de novo")
        #expect(AccountsCopy.action(for: .quota) == "Tentar de novo")
    }

    // MARK: A aparência

    @Test("A janela desenha no token do tema, em claro e em escuro")
    func fundoNoToken() throws {
        for id in ["tinta", "noite"] {
            let tema = try #require(Theme.named(id))
            let bitmap = try #require(Render.bitmap(
                AccountsList(
                    statuses: [status()],
                    onReconnect: { _ in }, onRetry: { _ in }, onRetryQueue: { _ in }, onRemove: { _ in }
                ),
                size: CGSize(width: 720, height: 400),
                theme: tema
            ))
            // O canto superior esquerdo é fundo puro: nenhum conteúdo desenha
            // lá. Se ele não estiver no token, a janela pintou cor literal.
            let cor = try #require(bitmap.colorAt(x: 4, y: 4))
            #expect(proximo(cor, tema.paper), "fundo fora do token no tema \(tema.id)")
        }
    }

    /// A divisória **chega na cor do token**, cheia, nas duas escalas.
    ///
    /// Só medir `pixelsWide` seria repetir o número passado ao `Render` — uma
    /// asserção verdadeira por construção. Esta conta os pixels que batem com
    /// `--line`: uma divisória desenhada com opacidade, com `Divider()` ou com
    /// qualquer mistura sai lavada e não chega a nenhum.
    ///
    /// A **espessura** é medida junto, varrendo uma coluna que só a divisória
    /// atravessa: a corrida de pixels diferentes do papel tem de ter exatamente
    /// 1, em 1× e em 2×. É o que impede alguém de engordar a linha para 2pt
    /// "para ficar visível".
    ///
    /// Registrado, com prova: `frame(height: 0.5)` cravado **não** é pego aqui,
    /// e não é pego por teste nenhum — os PNGs de 1× e de 2× saem byte a byte
    /// idênticos aos do código correto (MD5 conferido nas duas escalas). Numa
    /// superfície chapada o AppKit arredonda o retângulo de meio ponto para o
    /// pixel inteiro, e não sobra diferença para observar. Quem pega meio ponto
    /// é `HairlineThicknessTests`, nas bordas em `strokeBorder`, onde a metade
    /// não tem para onde arredondar.
    @Test("A divisória entre contas chega na cor do token e tem 1 pixel, em 1× e em 2×")
    func hairlineDeUmPixel() throws {
        let tema = try #require(Theme.named("tinta"))
        for escala in [CGFloat(1), CGFloat(2)] {
            let bitmap = try #require(Render.bitmap(
                AccountsList(
                    statuses: [status(), status()],
                    onReconnect: { _ in }, onRetry: { _ in }, onRetryQueue: { _ in }, onRemove: { _ in }
                ),
                size: CGSize(width: 720, height: 200),
                theme: tema, scale: escala
            ))
            #expect(bitmap.pixelsWide == Int(720 * escala))
            // Uma divisória atravessa os 720pt de largura. Em 1× isso são 720
            // pixels na cor exata; em 2×, 1440. O piso é a largura de **uma**
            // divisória, com folga para o que o texto por cima não cobre.
            let cheios = bitmap.pixels(matching: tema.line)
            #expect(
                cheios >= Int(600 * escala),
                "a divisória saiu lavada em \(escala)×: \(cheios) pixels no token"
            )

            // A coluna a 700pt está no recuo direito da linha: nenhum texto,
            // nenhum botão, só a divisória a atravessa.
            let corridas = corridasVerticais(
                em: bitmap, x: Int(700 * escala), fundo: tema.paper
            )
            #expect(
                corridas.allSatisfy { $0 == 1 } && !corridas.isEmpty,
                "a divisória não tem 1 pixel em \(escala)×: corridas \(corridas)"
            )
        }
    }

    /// Os comprimentos das sequências verticais de pixels que **não** são o
    /// fundo, na coluna `x`. Numa coluna atravessada só por divisórias, cada
    /// sequência é uma divisória e o comprimento dela é a espessura em pixels
    /// de dispositivo.
    private func corridasVerticais(
        em bitmap: NSBitmapImageRep, x: Int, fundo: TokenColor
    ) -> [Int] {
        guard let papel = fundo.nsColor.usingColorSpace(.sRGB) else { return [] }
        var corridas: [Int] = []
        var atual = 0
        for y in 0..<bitmap.pixelsHigh {
            let cor = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            let diferente = cor.map { abs($0.redComponent - papel.redComponent) > 0.005 } ?? false
            if diferente {
                atual += 1
            } else if atual > 0 {
                corridas.append(atual)
                atual = 0
            }
        }
        if atual > 0 { corridas.append(atual) }
        return corridas
    }

    @Test("A lista desenha zero, uma e trinta contas — e o conteúdo cresce com elas")
    func quantidadesExtremas() throws {
        // A VERSÃO ANTERIOR DESTE TESTE ERA INÚTIL, e a auditoria por mutação
        // deste marco provou: a única asserção era `bitmap.pixelsWide == 720`,
        // e 720 é o número que o próprio teste passou ao `Render` — verdadeira
        // por construção. Fazendo a `AccountsList` não desenhar conta nenhuma,
        // ela passava sozinha, enquanto cinco outros testes de pixel da mesma
        // suíte caíam. O "sem mudar de largura" do título não era medido em
        // lugar nenhum.
        //
        // O que se afirma agora é o conteúdo: a lista vazia não pinta linha
        // nenhuma, uma conta pinta, e trinta pintam mais que uma. A largura
        // continua sendo a mesma nas três — mas medida como **igualdade entre
        // os três desenhos**, e não contra a constante que o teste escolheu.
        //
        // MUTAÇÃO QUE ISTO PEGA: a mesma que a versão antiga deixava passar —
        // a `AccountsList` parar de desenhar as contas.
        let tema = try #require(Theme.named("tinta"))
        var larguras: Set<Int> = []
        var tinta: [Int: Int] = [:]
        for quantas in [0, 1, 30] {
            let lista = (0..<quantas).map { indice in
                AccountStatus(
                    accountID: "c\(indice)", address: "conta\(indice)@dominio.com",
                    hostMark: "host\(indice)", state: .ativa, messageCount: indice,
                    lastSyncedAt: nil, error: nil, progress: nil
                )
            }
            let bitmap = try #require(Render.bitmap(
                AccountsList(statuses: lista, onReconnect: { _ in }, onRetry: { _ in }, onRetryQueue: { _ in }, onRemove: { _ in }),
                size: CGSize(width: 720, height: 400), theme: tema
            ))
            larguras.insert(bitmap.pixelsWide)
            // O texto das linhas é `--ink`: contar esse tom é contar conteúdo,
            // e não a moldura.
            tinta[quantas] = bitmap.pixels(matching: tema.ink)
        }
        // A largura é a mesma nas três — afirmada por igualdade entre os
        // desenhos, que é o que o título promete.
        #expect(larguras.count == 1, "a largura mudou com a quantidade: \(larguras)")
        // Vazia não desenha conta nenhuma; uma desenha; trinta desenham mais.
        #expect(tinta[0] == 0, "a lista vazia pintou texto: \(tinta[0] ?? -1)")
        #expect((tinta[1] ?? 0) > 0, "uma conta não desenhou nada")
        #expect((tinta[30] ?? 0) > (tinta[1] ?? 0), "trinta contas não desenharam mais que uma")
    }

    /// Os três estados da linha desenham **diferente**.
    ///
    /// Uma linha que ignorasse o estado passaria em qualquer asserção de
    /// largura; o que ela não passa é numa comparação pixel a pixel entre uma
    /// conta sincronizada, uma carregando e uma em erro.
    @Test("Sincronizada, carregando e em erro são três desenhos diferentes")
    func tresEstadosTresDesenhos() throws {
        let tema = try #require(Theme.named("tinta"))
        func desenho(_ s: AccountStatus) throws -> NSBitmapImageRep {
            try #require(Render.bitmap(
                AccountsList(statuses: [s], onReconnect: { _ in }, onRetry: { _ in }, onRetryQueue: { _ in }, onRemove: { _ in }),
                size: CGSize(width: 720, height: 120), theme: tema
            ))
        }
        let ativa = try desenho(status())
        let carregando = try desenho(status(
            state: .carregando,
            progresso: LoadProgress(accountID: "conta-a", done: 250, total: 1_000)
        ))
        let comErro = try desenho(status(state: .erroDeAutenticacao, erro: .autenticacao))

        #expect(ativa.pixelsDiffering(from: carregando) > 0)
        #expect(ativa.pixelsDiffering(from: comErro) > 0)
        #expect(carregando.pixelsDiffering(from: comErro) > 0)
    }

    /// A conta em erro **oferece a saída**, e a saída combina com a causa.
    ///
    /// A lista de ações é pura porque é ela que o `body` percorre: a linha não
    /// decide botão nenhum sozinha. Uma linha que só oferecesse "Remover" a
    /// quem está com o token revogado é o defeito que esta janela existe para
    /// não repetir — conta parada, causa na tela e nenhuma saída.
    @Test("A conta em erro oferece a saída casada com a causa; a conta sã só oferece remover")
    func acoesDaLinha() {
        #expect(AccountsCopy.actions(for: status()) == [.remove])
        #expect(AccountsCopy.actions(for: status(state: .carregando)) == [.remove])

        let comAuth = AccountsCopy.actions(for: status(state: .erroDeAutenticacao, erro: .autenticacao))
        #expect(comAuth == [.reconnect(.autenticacao), .remove])
        #expect(comAuth.first?.label == "Reconectar")

        let comRede = AccountsCopy.actions(for: status(erro: .rede("tempo esgotado")))
        #expect(comRede == [.retry(.rede("tempo esgotado")), .remove])
        #expect(comRede.first?.label == "Tentar de novo")
    }

    /// **"Ver o roteiro" abre o roteiro — não chama `onReconnect`.**
    ///
    /// A linha oferece "Ver o roteiro" para `.semClientID` (`acaoCombinaComACausa`
    /// acima), mas antes desta task a ação por trás do rótulo era `.reconnect`,
    /// e `.reconnect` cai em `execute()` no mesmo `onReconnect` que
    /// "Reconectar" usa — que dispara `model.loadInitial`, uma tentativa de
    /// OAuth sem Client ID nenhum para tentar. A pessoa lia "Ver o roteiro",
    /// clicava, e o app tentava de novo o mesmo login que já falhou, em vez de
    /// abrir `docs/oauth-google.md`.
    ///
    /// O duplo de contadores — `onReconnect` e `onRetry` — é o que prova a
    /// fiação: com o defeito, `.semClientID` produzia `.reconnect(.semClientID)`
    /// e `reconectou` subiria para 1 ao executar a ação. Corrigido, a ação é
    /// `.openRoteiro`, nenhum dos dois contadores se move, e quem abre o
    /// arquivo é `AccountsDocs` diretamente.
    @Test("A ação de 'Ver o roteiro' é openRoteiro, e executá-la não chama reconectar nem tentar de novo")
    func verORoteiroNaoReconecta() {
        let comSemClientID = AccountsCopy.actions(for: status(state: .erroDeAutenticacao, erro: .semClientID))
        #expect(comSemClientID == [.openRoteiro, .remove])
        #expect(comSemClientID.first?.label == "Ver o roteiro")
        // Nem `.reconnect(.semClientID)` nem `.retry(.semClientID)`: a ação
        // não é nenhuma das duas outras — é uma terceira coisa.
        #expect(comSemClientID.first != .reconnect(.semClientID))
        #expect(comSemClientID.first != .retry(.semClientID))

        var reconectou = 0
        var tentou = 0
        let lista = AccountsList(
            statuses: [],
            onReconnect: { _ in reconectou += 1 },
            onRetry: { _ in tentou += 1 },
            onRetryQueue: { _ in },
            onRemove: { _ in }
        )
        lista.execute(.openRoteiro, on: "conta-a")
        #expect(reconectou == 0, "'Ver o roteiro' chamou onReconnect")
        #expect(tentou == 0, "'Ver o roteiro' chamou onRetry")
    }

    /// **A conta que volta quebrada do banco também tem saída.**
    ///
    /// O erro detalhado vive num dicionário de memória do `AccountDirector` e
    /// morre com o processo; `state` é coluna do banco. Reabrir o app com uma
    /// conta que perdeu o token na sessão passada dá exatamente este par —
    /// `state: .erroDeAutenticacao`, `error: nil` — e a versão anterior desta
    /// janela escrevia a causa inteira na tela e não oferecia botão nenhum.
    @Test("Conta reaberta em erro de autenticação, sem erro em memória, ainda oferece Reconectar")
    func erroPersistidoSemErroEmMemoria() {
        let persistida = status(state: .erroDeAutenticacao, erro: nil)

        #expect(AccountsCopy.isFailing(persistida))
        #expect(AccountsCopy.cause(of: persistida) == .autenticacao)
        #expect(AccountsCopy.actions(for: persistida) == [.reconnect(.autenticacao), .remove])
        // A frase já vinha do estado; o que faltava era a saída.
        #expect(AccountsCopy.status(persistida, now: agora, calendar: calendario)
            .contains(SyncError.autenticacao.mensagem))
    }

    /// A mesma conta, no pixel: a causa sai no realce e a ação é desenhada.
    @Test("A conta reaberta em erro desenha o realce e o botão, como a que errou agora")
    func erroPersistidoNoPixel() throws {
        let tema = try #require(Theme.named("tinta"))
        let sa = try realce(of: status(), tema: tema)
        let persistida = try realce(of: status(state: .erroDeAutenticacao, erro: nil), tema: tema)
        let daSessao = try realce(of: status(state: .erroDeAutenticacao, erro: .autenticacao), tema: tema)

        #expect(sa.faixaDosBotoes == 0, "a linha sã pintou realce na faixa dos botões")
        #expect(sa.total == 0, "a linha sã pintou realce onde não devia")
        #expect(persistida.total > 40, "a causa persistida não saiu no realce")
        #expect(persistida.faixaDosBotoes > 0, "a conta reaberta em erro não desenhou a ação")
        // As duas contam a mesma história e por isso desenham a mesma coisa.
        #expect(persistida.total == daSessao.total)
    }

    /// **A fiação entre a lista pura e os botões desenhados.**
    ///
    /// A regra virou função pura, e o `body` pode largá-la em silêncio: filtrar
    /// o `ForEach` para só "Remover" deixaria toda a parte pura verde. Aqui as
    /// duas etiquetas são contadas no bitmap, cada uma pela cor que lhe cabe —
    /// "Reconectar" em `--accent`, "Remover" em `--ink3` — na faixa da direita,
    /// onde nenhum texto da linha chega (medido: a linha sã tem 0 pixels de
    /// realce ali, e 68 de `--ink3`, que são o "Remover").
    @Test("Os dois botões da conta em erro chegam ao desenho, não só à lista pura")
    func fiacaoDaListaAteOsBotoes() throws {
        let tema = try #require(Theme.named("tinta"))
        let comErro = try realce(of: status(state: .erroDeAutenticacao, erro: .autenticacao), tema: tema)
        let sa = try realce(of: status(), tema: tema)

        #expect(comErro.faixaDosBotoes > 0, "'Reconectar' não foi desenhado")
        #expect(comErro.removerNaFaixa > 0, "'Remover' sumiu da linha em erro")
        #expect(sa.removerNaFaixa > 0, "'Remover' sumiu da linha sã")
        #expect(sa.faixaDosBotoes == 0, "a linha sã desenhou uma ação que não existe")
    }

    private struct Realce {
        /// Pixels de `--accent` na linha inteira.
        let total: Int
        /// Pixels de `--accent` na faixa dos botões: à direita de 600pt e na
        /// altura da **primeira linha** da linha da conta.
        ///
        /// As duas restrições são necessárias, e a segunda foi aprendida
        /// quebrando: só a horizontal deixava passar a mutação que apaga o
        /// botão, porque sem ele a coluna de texto se alarga e a frase do erro
        /// — que também é `--accent` — chega sozinha ao mesmo lugar. Na altura
        /// da primeira linha só existem o endereço (à esquerda, em `--ink`) e
        /// os botões; a frase do erro é a segunda linha.
        let faixaDosBotoes: Int
        /// Pixels de `--ink3` na mesma faixa: o "Remover".
        let removerNaFaixa: Int
    }

    private func realce(of s: AccountStatus, tema: Theme) throws -> Realce {
        let bitmap = try #require(Render.bitmap(
            AccountsList(statuses: [s], onReconnect: { _ in }, onRetry: { _ in }, onRetryQueue: { _ in }, onRemove: { _ in }),
            size: CGSize(width: 720, height: 120), theme: tema
        ))
        return Realce(
            total: bitmap.pixels(matching: tema.accent, tolerance: 0.06),
            faixaDosBotoes: conta(tema.accent, em: bitmap, aPartirDe: 600, linhas: Self.primeiraLinha),
            removerNaFaixa: conta(tema.ink3, em: bitmap, aPartirDe: 600, linhas: Self.primeiraLinha)
        )
    }

    /// A altura da primeira linha da linha da conta: 14pt de recuo superior
    /// mais os ~18pt que o corpo de 12,5pt ocupa.
    private static let primeiraLinha = 14..<32

    private func conta(
        _ token: TokenColor, em bitmap: NSBitmapImageRep,
        aPartirDe minX: Int, linhas: Range<Int>
    ) -> Int {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return 0 }
        var total = 0
        for y in linhas.clamped(to: 0..<bitmap.pixelsHigh) {
            for x in minX..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.9 else { continue }
                if abs(c.redComponent - alvo.redComponent) < 0.06,
                   abs(c.greenComponent - alvo.greenComponent) < 0.06,
                   abs(c.blueComponent - alvo.blueComponent) < 0.06 {
                    total += 1
                }
            }
        }
        return total
    }

    /// A causa do erro é desenhada em `--accent`; a linha sã não tem nada nesse
    /// realce. Prova que o estado de erro chega ao pixel, e não só ao texto.
    @Test("A linha em erro destaca a causa no realce do tema")
    func erroDesenhaNoRealce() throws {
        let tema = try #require(Theme.named("tinta"))
        func realce(_ s: AccountStatus) throws -> Int {
            let bitmap = try #require(Render.bitmap(
                AccountsList(statuses: [s], onReconnect: { _ in }, onRetry: { _ in }, onRetryQueue: { _ in }, onRemove: { _ in }),
                size: CGSize(width: 720, height: 120), theme: tema
            ))
            return bitmap.pixels(matching: tema.accent, tolerance: 0.06)
        }
        let semErro = try realce(status())
        let comErro = try realce(status(state: .erroDeAutenticacao, erro: .autenticacao))
        #expect(comErro > semErro + 40, "o erro não apareceu no realce: \(comErro) contra \(semErro)")
    }

    @Test("O formulário aparece só depois de o endereço ter rota")
    func formularioSegueARota() {
        // Regra do Marco 1: controle que existe faz alguma coisa. Um campo de
        // host antes de saber para onde ir seria um controle sem resposta.
        #expect(AddAccountForm.route(for: "") == nil)
        #expect(AddAccountForm.route(for: "ricardo@gmail.com") == .google)
        guard case .imap(let preset)? = AddAccountForm.route(for: "eu@icloud.com") else {
            Issue.record("esperava preset de iCloud"); return
        }
        #expect(preset.endpoint.port == 993)
        guard case .manual(let sugerido)? = AddAccountForm.route(for: "eu@dominio-proprio.com.br") else {
            Issue.record("esperava manual"); return
        }
        #expect(sugerido.host == "imap.dominio-proprio.com.br")
    }

    /// O formulário desenha no token, e a rota muda o que ele mostra.
    ///
    /// Sem endereço não há campo de host: o desenho vazio e o desenho com um
    /// endereço de iCloud têm de diferir, senão os campos apareceram antes de
    /// haver rota — que é o controle sem resposta que o teste puro acima
    /// proíbe, só que agora provado no pixel.
    @Test("O formulário desenha no token e só abre os campos com rota")
    func formularioNoToken() throws {
        let tema = try #require(Theme.named("tinta"))
        let modelo = AccountsModel(director: try Self.diretorDeTeste())
        let vazio = try #require(Render.bitmap(
            AddAccountForm(model: modelo),
            size: CGSize(width: 720, height: 260), theme: tema
        ))
        // No meio da altura, dentro dos 20pt de recuo: fundo puro do
        // formulário. O topo do bitmap não serve — o formulário mede o que
        // precisa e o quadro do harness é maior que ele.
        let cor = try #require(vazio.colorAt(x: 3, y: 130))
        #expect(proximo(cor, tema.surface), "o formulário pintou cor literal no fundo")

        let comRota = try #require(Render.bitmap(
            AddAccountForm(model: modelo, initialAddress: "eu@icloud.com"),
            size: CGSize(width: 720, height: 260), theme: tema
        ))
        // Os campos são caixas de `--surface2`. Sem endereço há **uma** (a do
        // próprio endereço); com a rota do iCloud há quatro — senha, host e
        // porta entram. Medir a área dessas caixas é o que separa "mudou
        // alguma coisa" de "os campos apareceram": um formulário que abrisse
        // host e porta antes de saber a rota pinta a mesma área nos dois.
        let caixasVazio = vazio.pixels(matching: tema.surface2)
        let caixasComRota = comRota.pixels(matching: tema.surface2)
        #expect(
            caixasComRota > caixasVazio * 2,
            "os campos não seguiram a rota: \(caixasVazio) contra \(caixasComRota)"
        )
    }

    @Test("Host em endereço numérico ganha a nota visível; nome de servidor não")
    func notaDoEnderecoNumerico() throws {
        // Conectar por IP continua permitido — servidor interno acessível só
        // por endereço existe. O que ele deixa de ser é silencioso: SNI não
        // aceita IP, e sem SNI o NIOSSL valida a cadeia mas não confere se o
        // certificado é **deste** servidor. Quem estiver no caminho apresenta
        // qualquer certificado válido emitido para um domínio dele, e a senha
        // de app da pessoa vai no LOGIN seguinte.
        //
        // A nota é medida em pixel de texto, e não por um `contains` numa
        // string: o que se promete é que ela **aparece na tela**.
        //
        // MUTAÇÃO QUE ISTO PEGA: apagar o `if ImapEndpoint.ehIPLiteral(host)`
        // do formulário iguala os dois desenhos.
        let tema = try #require(Theme.named("tinta"))
        let modelo = AccountsModel(director: try Self.diretorDeTeste())
        let medida = CGSize(width: 720, height: 300)

        let comNome = try #require(Render.bitmap(
            AddAccountForm(
                model: modelo, initialAddress: "eu@dominio-proprio.com.br",
                initialHost: "imap.dominio-proprio.com.br"
            ),
            size: medida, theme: tema
        ))
        let comIP = try #require(Render.bitmap(
            AddAccountForm(
                model: modelo, initialAddress: "eu@dominio-proprio.com.br",
                initialHost: "203.0.113.5"
            ),
            size: medida, theme: tema
        ))

        // A nota é desenhada em `--ink4`, o mesmo tom das outras legendas do
        // formulário — então o que a distingue é haver **mais** desse tom.
        let semNota = comNome.pixels(matching: tema.ink4)
        let comNota = comIP.pixels(matching: tema.ink4)
        #expect(
            comNota > semNota + 200,
            "a nota do endereço numérico não apareceu: \(semNota) contra \(comNota)"
        )
    }

    /// Um diretor que não fala com ninguém: banco descartável, cofre em
    /// memória, sem OAuth e com o IMAP recusando. Serve só para o formulário
    /// ter um modelo para desenhar — nenhum teste daqui dispara ação nenhuma.
    private static func diretorDeTeste() throws -> AccountDirector {
        AccountDirector(
            database: try SyncDatabase.temporary(),
            secrets: InMemorySecretStore(),
            auth: nil,
            session: .shared,
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            imapConnect: { _, _ in throw SyncError.rede("o teste não abre conexão") }
        )
    }

    /// Duas cores batem, com a tolerância de 0,02 por canal que a suíte usa.
    private func proximo(_ cor: NSColor, _ token: TokenColor) -> Bool {
        guard let a = cor.usingColorSpace(.sRGB),
              let b = token.nsColor.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}

/// O ponto de estado na linha da conta da lateral.
///
/// Conta parada sem sinal nenhum é o defeito que a janela de Contas existe para
/// não repetir — mas quem passa o dia na caixa de entrada olha a lateral, não a
/// janela de Contas. O desenho real, afirmado aqui: conta **ativa não tem
/// ponto**; conta **carregando** tem um ponto de 6pt em `--ink4`; conta em
/// **erro** tem o mesmo ponto em `--accent`.
@Suite("O ponto de estado da lateral")
@MainActor
struct SidebarAccountStateDotTests {

    private func store(_ state: Account.State) async -> MailStore {
        let conta = Account(
            id: "a0", address: "contato@meusite.com", displayName: "Site",
            provider: .imap, host: "meusite",
            tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9",
            state: state
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [conta], messages: [], agenda: [])
        )
        await store.load()
        return store
    }

    private func desenho(_ state: Account.State) async throws -> NSBitmapImageRep {
        let store = await store(state)
        return try #require(Render.bitmap(
            FolderSidebar(store: store),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 700),
            theme: .tinta
        ))
    }

    @Test("Ativa não tem ponto; carregando e erro têm, e não são o mesmo ponto")
    func oPontoSegueOEstado() async throws {
        let ativa = try await desenho(.ativa)
        let carregando = try await desenho(.carregando)
        let erro = try await desenho(.erroDeAutenticacao)

        #expect(ativa.pixelsDiffering(from: carregando) > 0, "a conta carregando desenhou igual à ativa")
        #expect(ativa.pixelsDiffering(from: erro) > 0, "a conta em erro desenhou igual à ativa")
        #expect(
            carregando.pixelsDiffering(from: erro) > 0,
            "carregando e erro desenharam o mesmo ponto — a cor não segue o estado"
        )
    }

    /// A cor de cada ponto, e não só "mudou alguma coisa": o de erro é
    /// `--accent`, o de carregando é `--ink4`, e a conta ativa não acrescenta
    /// nem um nem outro.
    @Test("O ponto de erro é o realce do tema; o de carregando, não")
    func aCorDoPonto() async throws {
        let tema = Theme.tinta
        let ativa = try await desenho(.ativa)
        let carregando = try await desenho(.carregando)
        let erro = try await desenho(.erroDeAutenticacao)

        #expect(erro.pixels(matching: tema.accent) > ativa.pixels(matching: tema.accent))
        #expect(carregando.pixels(matching: tema.accent) == ativa.pixels(matching: tema.accent))
        #expect(carregando.pixels(matching: tema.ink4) > ativa.pixels(matching: tema.ink4))
    }
}

/// Os dois roteiros que a janela abre são **arquivos do aplicativo**.
///
/// A verificação é do empacotamento, e por isso olha o `project.yml`: o bundle
/// que roda a suíte é o do `xctest`, e nele os recursos do app não existem —
/// afirmar `Bundle.main.url(...) != nil` aqui seria afirmar o contrário do
/// esperado. O que trava o defeito real (renomear ou mover um `.md` e deixar o
/// botão apontando para o vazio) é exigir que o arquivo exista no repositório
/// **e** esteja declarado como recurso do alvo do app.
@Suite("Os roteiros embarcados")
struct AccountsDocsTests {

    /// A raiz do repositório, a partir deste arquivo:
    /// `<raiz>/Packages/UNIShell/Tests/UNIShellTests/<este arquivo>`.
    private var raiz: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // UNIShellTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // UNIShell
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // raiz
    }

    @Test("Os dois roteiros existem no repositório com o nome que o código pede")
    func arquivosExistem() {
        for nome in AccountsDocs.all {
            let caminho = raiz.appendingPathComponent("docs/\(nome).md").path
            #expect(FileManager.default.fileExists(atPath: caminho), "faltou docs/\(nome).md")
        }
    }

    @Test("Os dois entram no app como recurso, e não como link para a web")
    func declaradosComoRecurso() throws {
        let projeto = try String(contentsOf: raiz.appendingPathComponent("project.yml"), encoding: .utf8)
        for nome in AccountsDocs.all {
            #expect(
                projeto.contains("path: docs/\(nome).md"),
                "docs/\(nome).md não está declarado no project.yml"
            )
        }
        // Declarado como fonte compilável não serviria: o arquivo tem de ir
        // para a fase de recursos para existir dentro do `.app`.
        #expect(projeto.contains("buildPhase: resources"))
    }

    @Test("Sem bundle que os contenha, quem procura recebe nulo — e não um caminho inventado")
    func semBundleNaoInventa() {
        // É o caso do alvo de teste, e é por isso que os botões que abrem os
        // roteiros nascem desabilitados aqui, com o `help` dizendo onde está o
        // arquivo — em vez de abrirem um "arquivo não encontrado".
        #expect(AccountsDocs.url(AccountsDocs.oauthGoogle, in: Bundle(for: SondaDeBundle.self)) == nil)
    }
}

/// Só para pegar um `Bundle` que comprovadamente não tem os roteiros.
private final class SondaDeBundle {}
