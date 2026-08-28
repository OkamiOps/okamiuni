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
/// **Nada do dono é tocado.** O banco é um `SyncDatabase.temporary()`
/// descartável e o cofre é o `InMemorySecretStore` — o `mail.sqlite` do
/// contêiner e o Keychain de verdade ficam de fora do ensaio inteiro.
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
    @MainActor
    public static func makeModel() -> AccountsModel? {
        guard fromProcess != nil else { return nil }
        do {
            let banco = try SyncDatabase.temporary()
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard let janela = view.window else {
                RehearsalStage.log("contas: FALHOU: sem janela")
                NSApp.terminate(nil)
                return
            }
            guard let model else {
                RehearsalStage.log("contas: FALHOU: a composição não montou o AccountsModel")
                NSApp.terminate(nil)
                return
            }
            await AccountsDriver(window: janela, model: model).run()
            NSApp.terminate(nil)
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

        // A janela precisa ser a chave do app ativo: é a janela-chave que
        // recebe as teclas que saem da fila em `NSApp.postEvent`. Sem isto o
        // que o ensaio digita não chega a campo nenhum — a lição da Task AQ.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await espera()

        // 2. O estado inicial: nenhuma conta.
        await assinaOModelo()
        afirma(model.statuses.isEmpty, "lista começa vazia")
        await fotografa("contas-01-vazio")

        // 3. O campo do formulário, com tecla de verdade.
        await digitaOEndereco()
        await fotografa("contas-02-endereco")

        // 4. Testar com senha certa, contra o servidor local.
        let endpoint = ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
        let passou = await model.testImap(
            address: AccountsRehearsal.endereco,
            password: AccountsRehearsal.senha,
            endpoint: endpoint
        )
        afirma(passou, "teste de conexão passou")
        afirma(model.lastError == nil, "teste não deixou erro")
        await fotografa("contas-03-testado")

        // 5. Adicionar e carregar.
        await model.addImap(
            address: AccountsRehearsal.endereco,
            password: AccountsRehearsal.senha,
            endpoint: endpoint, hostMark: "meusite", displayName: "Site"
        )
        afirma(model.statuses.count == 1, "a conta entrou na lista")
        // A carga corre solta — `addImap` devolve assim que a conta existe. O
        // ensaio espera pelo **efeito** dela, e não por um relógio: dormir um
        // tanto fixo é como um ensaio começa a passar numa máquina e falhar na
        // outra.
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
        guard let campo = Self.primeiroCampo(em: window.contentView) else {
            afirma(false, "o formulário não expôs campo de texto nenhum")
            return
        }
        let centro = campo.convert(CGPoint(x: campo.bounds.midX, y: campo.bounds.midY), to: nil)
        driver.click(at: centro)
        await espera()
        let editor = window.firstResponder as? NSText
        afirma(editor != nil, "o clique pôs o foco no campo de endereço")

        for caractere in AccountsRehearsal.endereco {
            driver.send(key: 0, characters: String(caractere))
        }
        await espera()
        let escrito = (window.firstResponder as? NSText)?.string ?? campo.stringValue
        afirma(
            escrito == AccountsRehearsal.endereco,
            "o campo recebeu o que foi digitado (leu «\(escrito)»)"
        )
    }

    /// O primeiro `NSTextField` da árvore — o campo de endereço é o único do
    /// formulário, e é o primeiro em ordem de desenho.
    private static func primeiroCampo(em view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let campo = view as? NSTextField, campo.isEditable { return campo }
        for filho in view.subviews {
            if let achado = primeiroCampo(em: filho) { return achado }
        }
        return nil
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
    private func esperaAte(segundos: Int, _ condicao: @MainActor () -> Bool) async -> Bool {
        let fim = Date().addingTimeInterval(TimeInterval(segundos))
        while Date() < fim {
            if condicao() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return condicao()
    }

    private func fotografa(_ nome: String) async {
        try? await Task.sleep(for: .milliseconds(120))
        driver.shoot(nome)
    }
}
