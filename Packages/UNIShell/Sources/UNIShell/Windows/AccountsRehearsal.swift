import Foundation
import NIOCore
import NIOPosix
import SwiftUI
import UNICore
import UNISync
#if canImport(AppKit)
import AppKit
#endif

/// Ensaia a janela de Contas **dentro do app de verdade**.
///
/// ## Por que existe
///
/// Regra do projeto, ganha a duro no Marco 1: interação de UI nova ganha ensaio
/// no app real. `SwipeRehearsal` provou que teste de View com o modelo verde
/// não é prova de que o clique chega — o gesto foi consertado três vezes com
/// teste passando e continuou morto na mão do dono do projeto.
///
/// O que este instrumento faz, sem tocar no mouse nem no teclado da máquina e
/// sem sair dela: sobe um servidor IMAP falso em `127.0.0.1`, abre a janela de
/// Contas, **clica no campo e digita** o endereço com eventos sintetizados
/// dentro do processo, testa a conexão contra o servidor local, adiciona a
/// conta, espera a carga inicial descer, passa pela rota Google e remove a
/// conta — fotografando cada fase. As afirmações vão para o stderr, uma por
/// linha, com `ok:` ou `FALHOU:`.
///
/// **Nenhuma rede externa.** O IMAP é local (`ImapSession.connectForRehearsal`
/// recusa qualquer host que não seja a própria máquina) e não há OAuth: o
/// diretor do ensaio nasce sem `GoogleAuth`, que é exatamente o estado que a
/// rota Google tem de explicar em vez de calar.
///
/// **Nada do dono é escrito.** O banco do ensaio é um `SyncDatabase.temporary()`
/// descartável e o cofre é o `InMemorySecretStore`: o Keychain de verdade não é
/// tocado, e o `mail.sqlite` do contêiner não recebe uma linha — nenhuma conta,
/// nenhuma mensagem, nenhum segredo.
///
/// A frase que estava aqui dizia que o `mail.sqlite` ficava "de fora do ensaio
/// inteiro", e desde a Task 18 isso deixou de ser literal: a composição do app
/// abre e migra o banco do contêiner em **todo** lançamento, inclusive neste. O
/// que o ensaio garante é o que importa — ele não lê nem escreve nada lá; ele
/// dirige o seu próprio banco descartável, e o apaga ao terminar.
///
/// `open -g --args --ensaiar-contas` liga; sem a bandeira, nada acontece.
public struct AccountsRehearsal: Sendable {
    public static func parse(_ arguments: [String]) -> AccountsRehearsal? {
        arguments.contains("--ensaiar-contas") ? AccountsRehearsal() : nil
    }

    public static var fromProcess: AccountsRehearsal? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }

    /// O endereço que o ensaio digita. Domínio que não é de provedor conhecido,
    /// de propósito: é o que faz a rota cair no formulário IMAP, que é a rota
    /// que este ensaio percorre até o fim.
    public static let endereco = "contato@meusite.com"
    public static let senha = "senha-de-app"
    /// O endereço da rota Google — a que só vai até a mensagem do client ID.
    public static let enderecoGoogle = "ricardo@gmail.com"

    /// O diretório do banco descartável desta rodada, para ser apagado antes do
    /// `terminate`. `nil` quando não há ensaio.
    @MainActor private static var diretorioDoBanco: String?

    /// Apaga o banco desta rodada e os órfãos das anteriores.
    ///
    /// **Por que à mão.** `SyncDatabase.temporary()` apaga o diretório no
    /// `deinit` do dono, e o `deinit` nunca chega: quem encerra o ensaio é
    /// `NSApp.terminate(nil)`, que derruba o processo sem desmontar nada. Cada
    /// execução deixava um `okamiuni-<UUID>/` para trás no `tmp` do contêiner —
    /// eram vinte quando isto foi notado. Instrumento que suja a máquina de quem
    /// o roda tem um defeito, mesmo que meça certo.
    ///
    /// Varre o prefixo inteiro, e não só o desta rodada, porque limpar o próprio
    /// rastro não recolhe o que já ficou; a varredura roda **antes** de o banco
    /// desta rodada existir, então ela nunca apaga o que está em uso.
    ///
    /// O diretório é parâmetro (com o `tmp` do contêiner por padrão) para o
    /// teste poder apontá-lo a uma pasta que ele mesmo criou. Varrer o `tmp` do
    /// processo dentro de um teste apagaria os bancos temporários de qualquer
    /// suíte rodando ao lado.
    @discardableResult
    static func limpaBancosDoEnsaio(
        em diretorio: URL = FileManager.default.temporaryDirectory
    ) -> Int {
        let nomes = (try? FileManager.default.contentsOfDirectory(atPath: diretorio.path)) ?? []
        var apagados = 0
        for nome in nomes where nome.hasPrefix("okamiuni-") {
            try? FileManager.default.removeItem(at: diretorio.appendingPathComponent(nome))
            apagados += 1
        }
        return apagados
    }

    /// O rastro desta rodada, apagado no fim dela.
    @MainActor
    static func limpaOBancoDaRodada() {
        guard let diretorio = diretorioDoBanco else { return }
        try? FileManager.default.removeItem(atPath: diretorio)
        diretorioDoBanco = nil
    }

    // MARK: A composição do ensaio

    /// O `AccountsModel` que o ensaio dirige, montado inteiro aqui.
    ///
    /// A composição mora **no ensaio** e não no `App` porque tudo nela é
    /// descartável: banco temporário, cofre em memória, sem OAuth, e um
    /// `EventLoopGroup` de uma thread que morre com o processo. A composição de
    /// verdade — banco do contêiner, Keychain, `GoogleAuth` — é da Task 18, e
    /// nada aqui deve virar atalho para ela.
    ///
    /// Nulo quando o banco temporário não pôde ser aberto. O ensaio registra e
    /// encerra, em vez de fingir que passou.
    ///
    /// Em Release a composição não existe: `ImapSession.connectForRehearsal` é
    /// `#if DEBUG`, e é assim que a promessa "produção sempre TLS" volta a ser
    /// fato do compilador. A bandeira num binário de Release diz isso e segue.
    @MainActor
    public static func makeModel() -> AccountsModel? {
        guard fromProcess != nil else { return nil }
        #if !DEBUG
        RehearsalStage.log(
            "contas: o ensaio não existe neste binário — ele é de Debug, "
            + "porque a conexão em claro que ele usa também é."
        )
        return nil
        #else
        do {
            // Antes de criar o desta rodada, varre os das rodadas anteriores.
            // Ver `limpaBancosDoEnsaio` — havia vinte deles no contêiner.
            _ = limpaBancosDoEnsaio()
            let banco = try SyncDatabase.temporary()
            // De onde o diretório desta rodada será apagado no fim: o `deinit`
            // que apagaria sozinho nunca roda, porque quem encerra o ensaio é
            // `NSApp.terminate`.
            diretorioDoBanco = (banco.pool.path as NSString).deletingLastPathComponent
            let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let diretor = AccountDirector(
                database: banco,
                secrets: InMemorySecretStore(),
                // Sem `GoogleAuth`: é o estado que a rota Google tem de
                // explicar, e o ensaio o fotografa.
                auth: nil,
                session: URLSession(configuration: .ephemeral),
                eventLoopGroup: grupo,
                imapConnect: { endpoint, grupo in
                    try await ImapSession.connectForRehearsal(endpoint: endpoint, group: grupo)
                }
            )
            return AccountsModel(director: diretor)
        } catch {
            RehearsalStage.log("contas: FALHOU: banco temporário não abriu — \(error)")
            return nil
        }
        #endif
    }
}

extension View {
    /// `model` nulo significa que a composição não montou o `UNISync` (por
    /// exemplo, num alvo sem banco). O ensaio registra isso e encerra, em vez
    /// de fingir que passou.
    public func rehearseAccountsIfRequested(
        _ request: AccountsRehearsal?, model: AccountsModel?
    ) -> some View {
        modifier(AccountsRehearsalModifier(request: request, model: model))
    }
}

private struct AccountsRehearsalModifier: ViewModifier {
    let request: AccountsRehearsal?
    let model: AccountsModel?
    @State private var started = false

    func body(content: Content) -> some View {
        content.background(
            AccountsProbe(request: request, model: model, started: $started)
                .frame(width: 0, height: 0)
        )
    }
}

private struct AccountsProbe: NSViewRepresentable {
    let request: AccountsRehearsal?
    let model: AccountsModel?
    @Binding var started: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard request != nil, !started else { return }
        started = true
        // Toda saída deste instrumento passa por aqui: apaga o banco
        // descartável e só então derruba o processo. `terminate` não desmonta
        // nada, então quem não apagar à mão deixa o diretório para trás.
        func encerra() {
            AccountsRehearsal.limpaOBancoDaRodada()
            NSApp.terminate(nil)
        }
        // O relógio de guarda. Um ensaio que trava é pior do que um que falha:
        // ele não diz nada e deixa um app aberto na máquina de quem o rodou.
        // Aconteceu de verdade nesta tarefa, no clique que abre o dropdown.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            RehearsalStage.log("contas: FALHOU: o ensaio estourou o relógio de guarda")
            encerra()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard let janela = view.window else {
                RehearsalStage.log("contas: FALHOU: sem janela")
                encerra()
                return
            }
            guard let model else {
                RehearsalStage.log("contas: FALHOU: a composição não montou o AccountsModel")
                encerra()
                return
            }
            await AccountsDriver(window: janela, model: model).run()
            encerra()
        }
    }
}

@MainActor
private final class AccountsDriver {
    private let driver: RehearsalDriver
    private let model: AccountsModel
    private let servidor = RehearsalImapServer()
    private var falhas = 0

    private var window: NSWindow { driver.window }

    init(window: NSWindow, model: AccountsModel) {
        self.driver = RehearsalDriver(window: window)
        self.model = model
    }

    func run() async {
        // 1. O servidor local.
        let porta: Int
        do {
            porta = try servidor.start()
            RehearsalStage.log("contas: ok: servidor IMAP falso em 127.0.0.1:\(porta)")
        } catch {
            RehearsalStage.log("contas: FALHOU: servidor não subiu — \(error)")
            return
        }
        defer { servidor.stop() }

        // A janela é ordenada para a frente **do app**, e o app não é trazido
        // para a frente da tela.
        //
        // Este ensaio não precisa disso, e a diferença veio à tona medindo: o
        // instrumento pedia `NSApp.activate` e ficava oito segundos sem
        // ganhá-la — um app lançado por trás não decide quem fica na frente, o
        // sistema decide, e decide conforme quem já está lá. Um ensaio que
        // depende de ganhar essa disputa passa numa rodada e falha na seguinte
        // sem nada ter mudado no código.
        //
        // A ativação só é obrigatória para atalho com ⌘, que corre em
        // `NSApplication.sendEvent` — é o caso do `KeyboardRehearsal`, e é por
        // isso que ele a pede. Aqui tudo é clique e caractere dentro de uma
        // janela, e para isso `NSWindow.sendEvent` é o cano certo: o mesmo por
        // onde o evento real chega depois que a `NSApplication` o entregou.
        // O ensaio roda sem tirar a frente de quem está usando a máquina.
        window.orderFront(nil)
        await espera()

        // 2. O estado inicial: nenhuma conta.
        await assinaOModelo()
        afirma(model.statuses.isEmpty, "lista começa vazia")
        await fotografa("contas-01-vazio")

        // 3. O campo do formulário, com tecla de verdade.
        await digitaOEndereco()
        await fotografa("contas-02-endereco")

        // 4. O formulário inteiro, apontado para o servidor local, e o clique
        //    de verdade em "Testar e adicionar".
        //
        //    Este é o clique mais importante da janela — o que conecta, grava a
        //    senha no cofre e põe a conta na lista —, e por isso ele é feito, e
        //    não simulado com uma chamada ao modelo. O que o ensaio afere é o
        //    efeito: a conta que aparece traz a **marca do host que o
        //    formulário calculou**, não uma que o driver tenha passado. Ela só
        //    pode ter vindo dali.
        await apontaOFormularioParaOServidorLocal(porta: porta)
        afirma(model.statuses.isEmpty, "nada foi gravado antes do clique")
        await clicaEmTestarEAdicionar()
        // O quadro do clique sai **no mesmo instante**, sem folga nenhuma: ele
        // mostra o formulário como estava quando o botão foi apertado, apontado
        // para o servidor local.
        //
        // Sem folga porque com folga não existe quadro nenhum para tirar.
        // Contra um servidor em 127.0.0.1 a conexão, o login e as duas
        // mensagens acontecem mais rápido do que uma volta do runloop: mesmo
        // fotografando no primeiro instante em que `isBusy` fica verdadeiro, e
        // sondando de 10 em 10ms, o quadro saía byte a byte igual ao da fase
        // seguinte — conferido por MD5. O estado "Carregando…" não chega a
        // existir na tela, e fingir que chega seria o instrumento mentindo.
        // Quem prova que a carga aconteceu são as afirmações e o quadro 04.
        driver.shoot("contas-03-clique")
        let entrou = await esperaAte(segundos: 20) { [model] in !model.statuses.isEmpty }
        afirma(entrou, "o clique em «Testar e adicionar» passou no teste e gravou a conta")
        afirma(model.lastError == nil, "o clique não deixou erro")
        afirma(
            model.statuses.first?.address == AccountsRehearsal.endereco,
            "a conta gravada é a do endereço digitado"
        )
        afirma(
            model.statuses.first?.hostMark == "meusite",
            "a marca do host veio do formulário (leu «\(model.statuses.first?.hostMark ?? "—")»)"
        )

        // 5. A carga corre solta — o botão devolve assim que a conta existe. O
        //    ensaio espera pelo **efeito** dela, e não por um relógio: dormir um
        //    tanto fixo é como um ensaio começa a passar numa máquina e falhar
        //    na outra.
        let carregou = await esperaAte(segundos: 20) { [model] in
            model.statuses.first?.state != .carregando
        }
        afirma(carregou, "a carga inicial terminou")
        afirma(model.statuses.first?.messageCount == 2, "as duas mensagens desceram para o banco")
        afirma(model.statuses.first?.state == .ativa, "a conta terminou ativa")
        afirma(model.statuses.first?.error == nil, "sem erro depois da carga")
        await fotografa("contas-04-carregada")

        // 6. A rota Google, sem client ID: a janela explica em vez de calar.
        await model.addGoogle(address: AccountsRehearsal.enderecoGoogle)
        if case .semClientID = model.lastError {
            afirma(true, "rota google sem client ID explica o que falta")
        } else {
            afirma(false, "rota google devolveu \(model.lastError?.mensagem ?? "nada")")
        }
        await fotografa("contas-05-google")

        // 7. Remover, com o banco e o cofre limpos.
        if let id = model.statuses.first?.accountID {
            await model.remove(id)
        } else {
            afirma(false, "não havia conta para remover")
        }
        let esvaziou = await esperaAte(segundos: 5) { [model] in model.statuses.isEmpty }
        afirma(esvaziou, "remover esvaziou a lista")
        await fotografa("contas-06-removida")

        RehearsalStage.log(
            falhas == 0
                ? "contas: ensaio inteiro passou"
                : "contas: FALHOU: \(falhas) afirmação(ões) do ensaio"
        )
    }

    // MARK: As fases que precisam de mão

    /// Assina o fluxo do diretor e espera o primeiro valor chegar.
    ///
    /// `AccountsModel.start()` fica assinado para sempre — ele é um `for await`
    /// que só termina com o fluxo. Esperá-lo aqui penduraria o ensaio; o que o
    /// ensaio precisa é do controle de volta depois da **primeira** publicação.
    /// A `AccountsWindow` já chama `start()` no `.task` dela, e assinar duas
    /// vezes é inofensivo: os dois laços escrevem o mesmo `statuses`.
    private func assinaOModelo() async {
        Task { await model.start() }
        await espera()
    }

    /// Clica no campo de endereço e digita, com eventos sintetizados na fila do
    /// próprio app.
    ///
    /// A afirmação não é "a foto ficou bonita": depois do clique o primeiro
    /// respondedor tem de ser o editor de campo do AppKit, e depois das teclas
    /// o texto dele tem de ser o endereço. É a diferença entre provar que a
    /// tecla chegou e torcer para que tenha chegado.
    private func digitaOEndereco() async {
        guard let campo = campos().first else {
            afirma(false, "o formulário não expôs campo de texto nenhum")
            return
        }
        driver.hit(at: centro(de: campo))
        await espera()
        afirma(window.firstResponder is NSText, "o clique pôs o foco no campo de endereço")

        digita(AccountsRehearsal.endereco)
        await espera()
        let escrito = (window.firstResponder as? NSText)?.string ?? campo.stringValue
        afirma(
            escrito == AccountsRehearsal.endereco,
            "o campo recebeu o que foi digitado (leu «\(escrito)»)"
        )
    }

    /// Preenche senha, forma de TLS, host e porta — nesta ordem, que não é
    /// arbitrária.
    ///
    /// A forma de TLS vem **antes** da porta porque escolhê-la reescreve a
    /// porta (`pick` do `ComposerSelect` põe 143 no STARTTLS); na ordem inversa
    /// o ensaio digitaria a porta do servidor falso e o próprio formulário a
    /// apagaria. E STARTTLS é a única forma que o servidor falso aceita: em
    /// `.tls` o primeiro byte já seria de um handshake, e ele não tem
    /// certificado nenhum.
    private func apontaOFormularioParaOServidorLocal(porta: Int) async {
        let campos = campos()
        // Endereço, senha, host, porta — a ordem em que `AddAccountForm` os
        // desenha, e a única coisa que este ensaio presume sobre o formulário.
        guard campos.count >= 4 else {
            afirma(false, "a rota IMAP não abriu os quatro campos (vi \(campos.count))")
            return
        }
        await preenche(campos[1], com: AccountsRehearsal.senha, oque: "senha de app")
        await escolheSTARTTLS(aoLadoDe: campos[3])
        // 143 é o que o `pick` do STARTTLS escreve na porta, e mais nada o
        // escreve. Ler isto é a prova de que a linha certa do menu foi clicada
        // — sem ela, o ensaio seguiria em `.tls` e a falha só apareceria três
        // fases adiante, com a cara de outro problema.
        let apos = await leitura(de: campos[3])
        afirma(apos == "143", "escolher STARTTLS trocou a porta para 143 (leu «\(apos)»)")
        await preenche(campos[2], com: "127.0.0.1", oque: "host")
        await preenche(campos[3], com: String(porta), oque: "porta")
    }

    /// Clica, apaga o que estava lá e digita por cima.
    ///
    /// Apagar é preciso: host e porta já vêm preenchidos pelo palpite da rota,
    /// e digitar por cima sem limpar deixaria `imap.meusite.com127.0.0.1`.
    ///
    /// Seta-para-a-direita e depois apagar, e não ⌘A: ⌘A é atalho, e atalho
    /// pede o app na frente da tela — o que este ensaio deixou de exigir de
    /// propósito. Setas e a tecla de apagar são teclas comuns, chegam pelo
    /// `sendEvent` da janela, e o resultado é o mesmo. O laço vai a 40 porque o
    /// maior palpite que o formulário escreve tem 17 caracteres: sobra é grátis,
    /// e uma seta a mais no fim do texto não move nada.
    private func preenche(_ campo: NSTextField, com texto: String, oque: String) async {
        driver.hit(at: centro(de: campo))
        await espera()
        for _ in 0..<40 { driver.type(key: RehearsalKey.right, characters: "\u{F703}") }
        for _ in 0..<40 { driver.type(key: RehearsalKey.delete, characters: "\u{8}") }
        digita(texto)
        await espera()
        let lido = (window.firstResponder as? NSText)?.string ?? campo.stringValue
        afirma(lido == texto, "o campo «\(oque)» ficou com \(texto) (leu «\(lido)»)")
    }

    /// Abre o dropdown de TLS e escolhe a segunda linha, STARTTLS.
    ///
    /// O `ComposerSelect` não é um `NSPopUpButton` — é o dropdown do design, e
    /// o menu dele é um `popover`, que no AppKit é **outra janela**. Daí as
    /// duas coisas incomuns aqui: o gatilho é localizado a partir do quadro do
    /// campo de porta (ele é o vizinho de 108pt à direita, no mesmo `HStack`, e
    /// nenhuma `NSView` o representa), e o clique da linha vai para a janela do
    /// popover, não para a principal.
    ///
    /// As duas opções são as únicas do menu, então a geometria do painel é
    /// conhecida: 8pt de recuo em cima e embaixo, duas linhas iguais, 2pt entre
    /// elas. A de baixo é a que se quer. E nada disto é presumido: a afirmação
    /// seguinte confere a porta em 143, que só o `pick` do STARTTLS escreve.
    private func escolheSTARTTLS(aoLadoDe porta: NSTextField) async {
        let quadro = porta.convert(porta.bounds, to: nil)
        let gatilho = NSPoint(x: quadro.maxX + 8 + 54, y: quadro.midY)
        let antes = Set(NSApp.windows.map(ObjectIdentifier.init))
        driver.hit(at: gatilho)
        await espera()
        guard let painel = NSApp.windows.first(where: {
            $0.isVisible && !antes.contains(ObjectIdentifier($0))
        }) else {
            afirma(false, "o dropdown de TLS não abriu painel nenhum")
            return
        }
        let alturaDaLinha = (painel.contentLayoutRect.height - 18) / 2
        driver.hit(at: NSPoint(x: 40, y: 8 + alturaDaLinha / 2), in: painel)
        await espera()
    }

    /// Clica em "Testar e adicionar".
    ///
    /// Nenhuma `NSView` representa o botão — ele é SwiftUI puro dentro do
    /// `NSHostingView`. A posição sai do quadro do campo de host, que é uma
    /// `NSView` de verdade: o botão é o próximo item do `VStack`, 12pt abaixo
    /// dele (o `spacing` do formulário), e o recuo à esquerda é o mesmo.
    private func clicaEmTestarEAdicionar() async {
        guard campos().count >= 3 else {
            afirma(false, "sem campo de host para localizar o botão")
            return
        }
        let host = campos()[2]
        let quadro = host.convert(host.bounds, to: nil)
        driver.hit(at: NSPoint(x: quadro.minX + 50, y: quadro.minY - 12 - 8))
    }

    // MARK: Teclado e árvore

    private func digita(_ texto: String) {
        for caractere in texto {
            // O código virtual não importa para um campo de texto: quem insere
            // é `interpretKeyEvents`, que lê `characters`. O que importa é o
            // evento sair pela fila do app, como os outros ensaios.
            driver.type(key: 0, characters: String(caractere))
        }
    }

    private func centro(de campo: NSView) -> NSPoint {
        campo.convert(CGPoint(x: campo.bounds.midX, y: campo.bounds.midY), to: nil)
    }

    /// Os campos de texto editáveis da janela, **na ordem em que se lê a tela**:
    /// de cima para baixo, e da esquerda para a direita dentro de uma mesma
    /// linha. Dá `[endereço, senha, host, porta]`.
    ///
    /// A ordem é geométrica, e não a da árvore, porque a da árvore não é a que
    /// se vê: as `NSView` de uma janela ficam em ordem de empilhamento, e o
    /// SwiftUI as acrescenta de trás para a frente. Presumir a ordem da árvore
    /// foi um erro medido — o ensaio clicou no campo de endereço achando que
    /// era o de porta, e o clique do dropdown caiu 34pt fora da janela.
    ///
    /// `NSSecureTextField` é `NSTextField`, então a senha entra aqui como as
    /// outras; é a posição, e não o tipo, que identifica cada campo.
    private func campos() -> [NSTextField] {
        var achados: [NSTextField] = []
        func caminha(_ view: NSView) {
            if let campo = view as? NSTextField, campo.isEditable { achados.append(campo) }
            for filho in view.subviews { caminha(filho) }
        }
        if let raiz = window.contentView { caminha(raiz) }
        return achados.sorted { a, b in
            let qa = a.convert(a.bounds, to: nil)
            let qb = b.convert(b.bounds, to: nil)
            // Em coordenadas do AppKit o y cresce para cima, então "mais alto
            // na tela" é y maior. Os 4pt de folga é o que separa duas linhas de
            // dois campos lado a lado na mesma linha.
            if abs(qa.midY - qb.midY) > 4 { return qa.midY > qb.midY }
            return qa.minX < qb.minX
        }
    }

    /// Clica num campo e lê o que ele tem, pelo editor de campo.
    ///
    /// `NSTextField.stringValue` **não serve** aqui: nos campos que o SwiftUI
    /// desenha ele devolve valor de outro campo ou vazio — foi ele que fez o
    /// ensaio afirmar que a porta continha o endereço de e-mail. O texto de
    /// verdade está no editor de campo, e o editor é do campo que tem o foco.
    private func leitura(de campo: NSTextField) async -> String {
        driver.hit(at: centro(de: campo))
        await espera()
        return (window.firstResponder as? NSText)?.string ?? ""
    }

    // MARK: Ferramentas

    private func afirma(_ condicao: Bool, _ oque: String) {
        if !condicao { falhas += 1 }
        RehearsalStage.log("contas: \(condicao ? "ok" : "FALHOU"): \(oque)")
    }

    private func espera() async {
        // Uma volta do runloop mais folga para o ator publicar e o SwiftUI
        // desenhar o que a publicação causou.
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// Espera por um **efeito**, com teto. Devolve `false` se o teto estourou.
    private func esperaAte(
        segundos: Int,
        passo: Duration = .milliseconds(150),
        _ condicao: @MainActor () -> Bool
    ) async -> Bool {
        let fim = Date().addingTimeInterval(TimeInterval(segundos))
        while Date() < fim {
            if condicao() { return true }
            try? await Task.sleep(for: passo)
        }
        return condicao()
    }

    private func fotografa(_ nome: String) async {
        try? await Task.sleep(for: .milliseconds(120))
        driver.shoot(nome)
    }
}
