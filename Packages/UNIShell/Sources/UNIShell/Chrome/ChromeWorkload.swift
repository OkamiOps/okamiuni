import Foundation
import UNICore
import UNISync

/// Que trabalho da IA está no ar — o que a frase da barra precisa dizer.
public enum AssistantWorkKind: Equatable, Sendable {
    case question
    case draft
    case briefing
}

/// Um trabalho longo, do ponto de vista de quem espera.
///
/// A barra fina do chrome nasceu falando só de sincronização, e o dono
/// aprendeu a reconhecê-la como "está carregando". Tudo o mais que o segura
/// esperando — a IA pensando, a fila de análise, o acervo, o corpo do email —
/// tinha de aparecer no mesmo lugar; senão o app tem duas linguagens para a
/// mesma ideia, e uma delas é o silêncio.
///
/// Um caso por trabalho, e não um `Bool` por trabalho espalhado pela `View`:
/// o rótulo e a fração são propriedades do trabalho, não da tela.
public enum ChromeWork: Equatable, Sendable {
    /// O que a barra já mostrava. Só conta como trabalho quando está
    /// `.loading` — `.ready`, `.failed` e `.empty` são repouso.
    case sync(MailboxChromeStatus)
    case assistant(kind: AssistantWorkKind, destination: AssistantDestination)
    /// A fila de análise automática com uma mensagem na mão agora.
    case analysisQueue
    /// A análise do acervo, que sabe onde está e quanto falta.
    case backlog(done: Int, total: Int)
    /// Um corpo de email sendo buscado sob demanda.
    case body

    /// Este trabalho está mesmo correndo?
    var isBusy: Bool {
        if case let .sync(status) = self { return status.isBusy }
        return true
    }

    /// A fração conhecida deste trabalho, quando ele tem uma honesta.
    var fraction: Double? {
        switch self {
        case let .sync(status):
            if case let .loading(fraction) = status { return fraction }
            return nil
        case let .backlog(done, total):
            guard total > 0 else { return nil }
            return min(1, max(0, Double(done) / Double(total)))
        case .assistant, .analysisQueue, .body:
            return nil
        }
    }

    /// A ordem em que os trabalhos aparecem na frase. Fixa, para dois
    /// trabalhos simultâneos não trocarem de lugar entre um quadro e outro —
    /// um rótulo que dança é ruído, não informação.
    var rank: Int {
        switch self {
        case .backlog: 0
        case .analysisQueue: 1
        case .assistant: 2
        case .body: 3
        case .sync: 4
        }
    }

    /// O que este trabalho diz de si mesmo no tooltip da barra.
    var label: String {
        switch self {
        case .sync:
            return "Sincronizando"
        case let .assistant(kind, destination):
            let verbo: String
            switch kind {
            case .question: verbo = "Perguntando"
            case .draft: verbo = "Escrevendo o rascunho"
            case .briefing: verbo = "Preparando o briefing"
            }
            if destination.isLocal { return "\(verbo) neste Mac" }
            // "Perguntando ao Codex · ChatGPT" para a pergunta; os outros dois
            // pedem "com", que é o que se faz com uma ferramenta.
            let ligacao = kind == .question ? "ao" : "com"
            return "\(verbo) \(ligacao) \(destination.label)"
        case .analysisQueue:
            return "Analisando mensagens"
        case let .backlog(done, total):
            guard total > 0 else { return "Analisando o acervo" }
            return "Analisando \(done) de \(total)"
        case .body:
            return "Carregando o email"
        }
    }
}

/// O estado único da barra fina, somado fora da `View`.
///
/// `status` é o que a barra desenha (ela já sabe desenhar os quatro casos);
/// `detail` é a frase do tooltip e da leitura em voz alta enquanto há
/// trabalho. `nil` em repouso, e aí vale a legenda de sempre ("Atualizada há
/// 4 min").
public struct ChromeWorkload: Equatable, Sendable {
    public let status: MailboxChromeStatus
    public let detail: String?

    public init(status: MailboxChromeStatus, detail: String?) {
        self.status = status
        self.detail = detail
    }

    public var isBusy: Bool { status.isBusy }

    /// A regra inteira, num lugar só.
    ///
    /// - Nada correndo: a barra continua sendo a da sincronização, com a
    ///   mesma prontidão, a mesma falha e o mesmo vazio de antes.
    /// - Algo correndo: a barra carrega. A falha de uma conta **não** apaga o
    ///   trabalho que continua — a mesma regra que `MailboxChromeStatus.from`
    ///   já aplicava dentro da sincronização, agora valendo entre trabalhos.
    /// - A fração só sai quando **um** trabalho a conhece. Dois progressos
    ///   diferentes numa barra só dariam um número que não é de ninguém; aí
    ///   ela respira, e a frase diz o que está acontecendo.
    public static func combining(_ jobs: [ChromeWork]) -> ChromeWorkload {
        let ocupados = jobs.filter(\.isBusy).sorted { $0.rank < $1.rank }
        guard !ocupados.isEmpty else {
            let sync = jobs.compactMap { work -> MailboxChromeStatus? in
                if case let .sync(status) = work { return status }
                return nil
            }.first
            return ChromeWorkload(status: sync ?? .empty, detail: nil)
        }
        let fracoes = ocupados.compactMap(\.fraction)
        let fracao = fracoes.count == 1 ? fracoes[0] : nil
        return ChromeWorkload(
            status: .loading(fraction: fracao),
            detail: ocupados.map(\.label).joined(separator: " · ")
        )
    }
}
