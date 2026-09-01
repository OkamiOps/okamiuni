import Foundation
import Observation
import UNICore

/// O que a janela de Contas observa.
///
/// `@Observable` vem do módulo `Observation`, não do SwiftUI — este pacote
/// continua sem importar SwiftUI, como a arquitetura manda. É a mesma escolha
/// que o `MailStore` do `UNICore` já faz.
///
/// **Nada de estado em dois lugares.** O modelo não guarda cópia de conta
/// nenhuma: ele repassa as ações ao diretor e desenha o que o fluxo publicar.
/// O banco é a verdade; isto aqui é a janela dela.
@MainActor
@Observable
public final class AccountsModel {
    public private(set) var statuses: [AccountStatus] = []
    /// O erro da última ação que a **janela** disparou (adicionar, testar,
    /// remover). Separado do erro por conta: um teste de conta que ainda não
    /// existe não tem conta a que pertencer.
    public private(set) var lastError: SyncError?

    /// Há uma ação da janela em curso — a que trava o formulário e gira o
    /// botão.
    ///
    /// **Não cobre a carga inicial.** Testar, gravar e remover levam segundos;
    /// baixar noventa dias leva minutos, e deixar o formulário travado por
    /// todo esse tempo faria a janela parecer pendurada bem quando ela está
    /// funcionando. O andamento da carga já chega pelo `progress` de cada
    /// `AccountStatus`, que é onde a janela o desenha.
    public private(set) var isBusy = false

    private let director: AccountDirector
    /// Quem leva a fila de saída ao servidor. Opcional porque nem toda montagem
    /// tem uma — os testes de janela montam o modelo só com o diretor, e o app
    /// sem banco não tem fila nenhuma para religar.
    private let outbox: OutboxRunner?
    /// Quem acorda o ciclo incremental. Nulo nos testes da janela, que não
    /// montam o `SyncRunner`.
    private let sync: SyncRunner?
    /// A última ação enfileirada. As ações da janela correm **uma de cada
    /// vez**: dois cliques no mesmo botão, ou remover enquanto adiciona,
    /// escreveriam no mesmo `lastError` e no mesmo `isBusy` e a segunda
    /// apagaria o relato da primeira.
    ///
    /// Espera, e não recusa: quem clicou duas vezes quis a ação duas vezes ou
    /// não quis nenhuma — e recusar em silêncio, com um erro que a pessoa não
    /// pediu, é pior do que fazer na ordem. Nada aqui é caro o bastante para
    /// justificar uma mensagem de "ocupado".
    private var fila: Task<Void, Never>?

    public init(
        director: AccountDirector, outbox: OutboxRunner? = nil, sync: SyncRunner? = nil
    ) {
        self.director = director
        self.outbox = outbox
        self.sync = sync
    }

    /// Assina o diretor. Chamada uma vez, na montagem da cena.
    public func start() async {
        for await lista in await director.statuses() {
            statuses = lista
        }
    }

    public func addGoogle(address: String) async {
        await roda {
            let conta = try await self.director.addGoogleAccount(address: address)
            self.carregaEmSegundoPlano(conta)
        }
    }

    /// Testa sem gravar. Devolve `true` quando passou, para a janela mostrar o
    /// resultado — e `lastError` explica quando não.
    @discardableResult
    public func testImap(address: String, password: String, endpoint: ImapEndpoint) async -> Bool {
        await roda {
            try await self.director.testImap(
                address: address, password: password, endpoint: endpoint
            )
        }
        return lastError == nil
    }

    public func addImap(
        address: String, password: String, endpoint: ImapEndpoint,
        hostMark: String, displayName: String
    ) async {
        await roda {
            let conta = try await self.director.addImapAccount(
                address: address, password: password, endpoint: endpoint,
                hostMark: hostMark, displayName: displayName
            )
            self.carregaEmSegundoPlano(conta)
        }
    }

    public func remove(_ accountID: String) async {
        await roda { try await self.director.remove(accountID: accountID) }
    }

    /// Grava a assinatura da conta e deixa o diretor publicar o retrato novo.
    ///
    /// Devolve `false` quando a ação falha; a causa completa continua em
    /// `lastError`, como nas demais ações da janela. O retorno é conveniente
    /// para um formulário que só deve fechar depois da confirmação, sem criar
    /// um segundo canal de erro.
    @discardableResult
    public func updateSignature(accountID: String, signature: String) async -> Bool {
        await updateEmailSignature(
            accountID: accountID, signature: EmailSignature(legacyText: signature)
        )
    }

    /// Grava a assinatura rica e preserva o retorno/erro da API antiga. A
    /// sanitização e os limites já foram aplicados por `EmailSignature`; este
    /// método apenas serializa a ação da janela e entrega a escrita ao banco.
    @discardableResult
    public func updateEmailSignature(
        accountID: String, signature: EmailSignature
    ) async -> Bool {
        await roda {
            _ = try await self.director.updateEmailSignature(
                accountID: accountID, signature: signature
            )
        }
        return lastError == nil
    }

    @discardableResult
    public func updateSendAliases(accountID: String, aliases: [SendAlias]) async -> Bool {
        await roda {
            _ = try await self.director.updateSendAliases(
                accountID: accountID, aliases: aliases
            )
        }
        return lastError == nil
    }

    @discardableResult
    public func refreshGmailSendAliases(accountID: String) async -> Bool {
        await roda {
            _ = try await self.director.refreshGmailSendAliases(accountID: accountID)
        }
        return lastError == nil
    }

    public func loadInitial(_ accountID: String) async {
        await director.loadInitial(accountID: accountID)
    }

    /// Sincroniza agora, sem esperar o ciclo de um minuto.
    ///
    /// Conta ativa é acordada no coordenador que já existe. Conta em erro
    /// retoma a carga — o mesmo caminho do "Tentar de novo" da janela.
    /// `.carregando` já está no ar; outra carga em cima leria o `sync_state`
    /// pela metade.
    public func syncNow() async {
        await sync?.wakeAll()
        for status in statuses {
            if status.error != nil || status.state == .erroDeAutenticacao {
                await loadInitial(status.accountID)
            }
        }
    }

    /// Religa a fila de saída parada desta conta.
    ///
    /// **Não é `loadInitial`.** As duas ações do erro de ciclo (reconectar,
    /// tentar de novo) caem na carga, e a carga baixa mensagens — ela não sabe
    /// da fila. Uma fila parada só sai do lugar por aqui: a trava mora no
    /// executor, e é ele quem devolve as linhas `falhou` a `pendente`.
    ///
    /// Fora do `roda`: não é ação de formulário, não tem erro a mostrar (o do
    /// executor já chega pela linha da conta) e não pode ficar esperando a vez
    /// atrás de uma carga de noventa dias.
    public func retryQueue(_ accountID: String) async {
        await outbox?.executor(for: accountID)?.retryAfterPermanentFailure()
    }

    /// A carga que segue sozinha depois de a conta entrar.
    ///
    /// Solta, e não esperada: a adição terminou quando a conta existe e a
    /// credencial está guardada. Esperar noventa dias de mensagens antes de
    /// devolver o controle à janela transformaria "adicionar conta" numa
    /// operação de minutos.
    ///
    /// Só para conta **nova**: uma re-adição volta com o estado que já tinha
    /// (`.ativa`, quase sempre), e a pessoa que só trocou a senha de app não
    /// pediu para baixar tudo de novo.
    private func carregaEmSegundoPlano(_ conta: Account) {
        guard conta.state == .carregando else { return }
        Task { await self.director.loadInitial(accountID: conta.id) }
    }

    /// Uma ação, com o ocupado ligado, o erro capturado e a vez respeitada.
    ///
    /// O `catch` é largo de propósito e **não** engole: todo erro vira
    /// `lastError`, que a janela mostra. O que não pode acontecer é a janela
    /// ficar com o botão girando para sempre porque alguém lançou algo que não
    /// era `SyncError`.
    private func roda(_ acao: @escaping @MainActor () async throws -> Void) async {
        let anterior = fila
        pendentes += 1
        let minha = Task { @MainActor in
            // A vez: esta ação só começa quando a anterior terminou.
            await anterior?.value
            isBusy = true
            lastError = nil
            do {
                try await acao()
            } catch let erro as SyncError {
                lastError = erro
            } catch {
                lastError = .rede(error.localizedDescription)
            }
            pendentes -= 1
            // Só a última da fila apaga o ocupado: desligá-lo com outra ação
            // já esperando faria o botão parar de girar no meio do trabalho.
            if pendentes == 0 { isBusy = false }
        }
        fila = minha
        await minha.value
        if pendentes == 0 { fila = nil }
    }

    /// Quantas ações estão na fila, contando a que corre agora.
    private var pendentes = 0
}
