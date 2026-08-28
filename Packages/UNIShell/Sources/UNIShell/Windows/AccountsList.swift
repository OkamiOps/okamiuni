import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// O que uma linha de conta oferece fazer.
///
/// Existe como valor, e não como três `if` dentro do `body`, pela mesma razão
/// que `AccountsCopy` existe: **qual** ação uma conta em erro oferece é regra
/// do produto — e a regra que separa reconectar de tentar de novo é a que
/// impede o app de mandar quem perdeu o wi-fi refazer o consentimento.
public enum AccountRowAction: Hashable, Sendable, Identifiable {
    /// Refazer a autorização. Só para quem perdeu a credencial.
    case reconnect(SyncError)
    /// Repetir a operação. Para o que passa sozinho: rede, TLS, quota.
    case retry(SyncError)
    /// Apagar a conta — destrutivo, e por isso pergunta antes.
    case remove

    public var id: String {
        switch self {
        case .reconnect: "reconnect"
        case .retry: "retry"
        case .remove: "remove"
        }
    }

    public var label: String {
        switch self {
        case .reconnect(let erro), .retry(let erro): AccountsCopy.action(for: erro)
        case .remove: "Remover"
        }
    }

    public var help: String {
        switch self {
        case .reconnect(let erro), .retry(let erro): AccountsCopy.actionHelp(for: erro)
        case .remove: "Apagar esta conta, as mensagens baixadas dela e a senha guardada"
        }
    }
}

/// Todo o texto da janela de Contas, num lugar puro.
///
/// Fora da `View` porque é decisão, não desenho: o que uma conta em erro diz e
/// que ação ela oferece são regras do produto, e regra dentro de `body` não se
/// testa sem renderizar.
public enum AccountsCopy {
    /// A linha de estado de uma conta.
    public static func status(_ s: AccountStatus, now: Date, calendar: Calendar) -> String {
        let contagem = "\(numero(s.messageCount)) \(s.messageCount == 1 ? "mensagem" : "mensagens")"

        if let erro = s.error {
            return "\(erro.mensagem) · \(contagem)"
        }
        switch s.state {
        case .carregando:
            if let progresso = s.progress, progresso.total > 0 {
                let porcento = Int((progresso.fraction * 100).rounded())
                return "Carregando… \(porcento)% · \(contagem)"
            }
            // Sem total conhecido não há porcentagem honesta. Uma barra que
            // finge 0% enquanto a página de ids ainda está sendo pedida é pior
            // do que dizer só "Carregando".
            return "Carregando… · \(contagem)"
        case .erroDeAutenticacao:
            return "\(SyncError.autenticacao.mensagem) · \(contagem)"
        case .ativa:
            guard let quando = s.lastSyncedAt else {
                return "Ainda não sincronizada · \(contagem)"
            }
            return "Sincronizada \(horario(quando, calendar: calendar)) · \(contagem)"
        }
    }

    /// A ação que o erro pede. Duas ações diferentes porque são dois problemas
    /// diferentes: mandar reconectar quem só perdeu o wi-fi é fazer a pessoa
    /// refazer o consentimento à toa.
    public static func action(for erro: SyncError) -> String {
        switch erro {
        case .autenticacao, .autorizacaoRevogada: "Reconectar"
        case .semClientID: "Ver o roteiro"
        default: "Tentar de novo"
        }
    }

    /// As ações da linha, na ordem em que ela as desenha.
    ///
    /// Conta sã oferece **uma**: remover. Conta em erro oferece duas, e a
    /// primeira é casada com a causa — reconectar para quem perdeu a
    /// credencial, tentar de novo para o que passa sozinho.
    public static func actions(for s: AccountStatus) -> [AccountRowAction] {
        var acoes: [AccountRowAction] = []
        if let erro = s.error {
            switch erro {
            case .autenticacao, .autorizacaoRevogada, .semClientID:
                acoes.append(.reconnect(erro))
            default:
                acoes.append(.retry(erro))
            }
        }
        acoes.append(.remove)
        return acoes
    }

    /// O balão da ação — por que ela é *esta* e não a outra. A regra do marco
    /// anterior vale igual aqui: controle que existe explica o que faz.
    public static func actionHelp(for erro: SyncError) -> String {
        switch erro {
        case .autenticacao, .autorizacaoRevogada:
            "Refazer a autorização desta conta"
        case .semClientID:
            "Abrir docs/oauth-google.md, que diz o que falta"
        default:
            "Repetir a última operação desta conta"
        }
    }

    /// "às 14:32". O `Calendar` vem de fora: hora de parede é da máquina de
    /// quem lê, e não do modelo — a mesma regra que mantém `dayOffset` inteiro.
    private static func horario(_ data: Date, calendar: Calendar) -> String {
        let partes = calendar.dateComponents([.hour, .minute], from: data)
        return String(format: "às %02d:%02d", partes.hour ?? 0, partes.minute ?? 0)
    }

    /// "1.284" — separador de milhar em pt-BR.
    private static func numero(_ valor: Int) -> String {
        let formatador = NumberFormatter()
        formatador.locale = Locale(identifier: "pt_BR")
        formatador.numberStyle = .decimal
        return formatador.string(from: NSNumber(value: valor)) ?? "\(valor)"
    }
}

/// A lista de contas: endereço, chip do provedor, estado e o que fazer.
public struct AccountsList: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    private let statuses: [AccountStatus]
    private let onReconnect: (String) -> Void
    private let onRetry: (String) -> Void
    private let onRemove: (String) -> Void

    public init(
        statuses: [AccountStatus],
        onReconnect: @escaping (String) -> Void,
        onRetry: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self.statuses = statuses
        self.onReconnect = onReconnect
        self.onRetry = onRetry
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if statuses.isEmpty {
                // Zero contas é estado legítimo, e não vazio mudo: o app está
                // nas fixtures, e a frase diz isso.
                Text("Nenhuma conta conectada. O app está mostrando dados de exemplo.")
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(statuses) { status in
                            row(status)
                            // A divisória do design: um pixel do dispositivo,
                            // na cor do token. Ver `Hairline.thickness(_:)`.
                            Rectangle()
                                .fill(theme.line.color)
                                .frame(height: Hairline.thickness(displayScale))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
    }

    private func row(_ status: AccountStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TintChip(label: status.hostMark, tint: theme.ink4.color, emphasized: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.address)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status.address)
                Text(AccountsCopy.status(status, now: Date(), calendar: .current))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(status.error == nil ? theme.ink3.color : theme.accent.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let progresso = status.progress, progresso.total > 0 {
                    ProgressView(value: progresso.fraction)
                        .tint(theme.accent.color)
                        .frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 12)
            // Os botões saem da lista pura: o `body` desenha o que
            // `AccountsCopy.actions(for:)` decidir, e não decide nada por
            // conta própria.
            ForEach(AccountsCopy.actions(for: status)) { acao in
                Button(acao.label) { execute(acao, on: status.accountID) }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 11.5, weight: acao == .remove ? .regular : .medium))
                    .foregroundStyle(acao == .remove ? theme.ink3.color : theme.accent.color)
                    .help(acao.help)
                    .focusRing(cornerRadius: theme.radiusSmall)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func execute(_ acao: AccountRowAction, on accountID: String) {
        switch acao {
        case .reconnect: onReconnect(accountID)
        case .retry: onRetry(accountID)
        case .remove: onRemove(accountID)
        }
    }
}
