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
        mensagens: Int = 1_284
    ) -> AccountStatus {
        AccountStatus(
            accountID: "conta-a", address: "contato@meusite.com", hostMark: "meusite",
            state: state, messageCount: mensagens, lastSyncedAt: sincronizada,
            error: erro, progress: progresso
        )
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
                    onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }
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
    /// qualquer mistura sai lavada e não chega a nenhum. Registrado do que ela
    /// **não** pega: `frame(height: 0.5)` cravado passa aqui, porque numa
    /// superfície chapada o AppKit arredonda o retângulo para o pixel inteiro.
    /// Quem pega meio ponto é `HairlineThicknessTests`, nas bordas em
    /// `strokeBorder`, onde a metade não tem para onde arredondar.
    @Test("A divisória entre contas chega na cor do token, em 1× e em 2×")
    func hairlineDeUmPixel() throws {
        let tema = try #require(Theme.named("tinta"))
        for escala in [CGFloat(1), CGFloat(2)] {
            let bitmap = try #require(Render.bitmap(
                AccountsList(
                    statuses: [status(), status()],
                    onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }
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
        }
    }

    @Test("A lista aguenta zero, uma e trinta contas sem mudar de largura")
    func quantidadesExtremas() throws {
        let tema = try #require(Theme.named("tinta"))
        for quantas in [0, 1, 30] {
            let lista = (0..<quantas).map { indice in
                AccountStatus(
                    accountID: "c\(indice)", address: "conta\(indice)@dominio.com",
                    hostMark: "host\(indice)", state: .ativa, messageCount: indice,
                    lastSyncedAt: nil, error: nil, progress: nil
                )
            }
            let bitmap = try #require(Render.bitmap(
                AccountsList(statuses: lista, onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }),
                size: CGSize(width: 720, height: 400), theme: tema
            ))
            #expect(bitmap.pixelsWide == 720)
        }
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
                AccountsList(statuses: [s], onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }),
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

    /// A causa do erro é desenhada em `--accent`; a linha sã não tem nada nesse
    /// realce. Prova que o estado de erro chega ao pixel, e não só ao texto.
    @Test("A linha em erro destaca a causa no realce do tema")
    func erroDesenhaNoRealce() throws {
        let tema = try #require(Theme.named("tinta"))
        func realce(_ s: AccountStatus) throws -> Int {
            let bitmap = try #require(Render.bitmap(
                AccountsList(statuses: [s], onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }),
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
