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
    /// Abrir `docs/oauth-google.md`. Só para `.semClientID` — não há
    /// credencial para refazer nem operação para repetir: falta configurar o
    /// app, e o roteiro é o que diz como.
    case openRoteiro
    /// Apagar a conta — destrutivo, e por isso pergunta antes.
    case remove

    public var id: String {
        switch self {
        case .reconnect: "reconnect"
        case .retry: "retry"
        case .openRoteiro: "openRoteiro"
        case .remove: "remove"
        }
    }

    public var label: String {
        switch self {
        case .reconnect(let erro), .retry(let erro): AccountsCopy.action(for: erro)
        case .openRoteiro: AccountsCopy.action(for: .semClientID)
        case .remove: "Remover"
        }
    }

    public var help: String {
        switch self {
        case .reconnect(let erro), .retry(let erro): AccountsCopy.actionHelp(for: erro)
        case .openRoteiro: AccountsCopy.actionHelp(for: .semClientID)
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

    /// A conta está quebrada — pelo erro **desta sessão** ou pelo estado que o
    /// banco guardou.
    ///
    /// Os dois, e não só o primeiro. `AccountStatus.error` mora num dicionário
    /// de memória do `AccountDirector` e morre com o processo; `state` é
    /// coluna do banco e sobrevive. Abrir o app com uma conta que perdeu o
    /// token na sessão passada dá `state == .erroDeAutenticacao` e
    /// `error == nil` — e uma janela que só olhasse `error` mostraria a causa
    /// (que `status(_:)` tira do estado) sem oferecer saída nenhuma. Conta
    /// parada com a queixa na tela e nenhum botão é o defeito que esta janela
    /// existe para não repetir.
    public static func isFailing(_ s: AccountStatus) -> Bool {
        s.error != nil || s.state == .erroDeAutenticacao
    }

    /// O erro que a linha trata — o desta sessão, quando há; senão o que o
    /// estado persistido implica.
    ///
    /// `.erroDeAutenticacao` só chega ao banco por credencial recusada ou
    /// revogada, e as duas pedem a mesma ação. É a mesma tradução que
    /// `status(_:)` já faz para escrever a frase.
    public static func cause(of s: AccountStatus) -> SyncError? {
        if let erro = s.error { return erro }
        return s.state == .erroDeAutenticacao ? .autenticacao : nil
    }

    /// As ações da linha, na ordem em que ela as desenha.
    ///
    /// Conta sã oferece **uma**: remover. Conta quebrada oferece duas, e a
    /// primeira é casada com a causa — reconectar para quem perdeu a
    /// credencial, tentar de novo para o que passa sozinho.
    public static func actions(for s: AccountStatus) -> [AccountRowAction] {
        var acoes: [AccountRowAction] = []
        if let erro = cause(of: s) {
            switch erro {
            case .autenticacao, .autorizacaoRevogada:
                acoes.append(.reconnect(erro))
            case .semClientID:
                // Não é reconectar: não há credencial revogada para refazer,
                // é o app que não foi configurado com um Client ID. Mandar
                // isto para `onReconnect` (que dispara `loadInitial`) repetia
                // um OAuth sem nada para tentar — ver `verORoteiroNaoReconecta`.
                acoes.append(.openRoteiro)
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
///
/// ## De onde vêm os números
///
/// **Esta tela não existe no protótipo.** O Marco 1 desenhou quatro janelas e
/// nenhuma delas é esta, então não há linha de `.dc.html` para citar — e por
/// isso os números não podem ser apresentados como se houvesse.
///
/// Eles são **derivados das janelas do Marco 1**, para a de Contas não parecer
/// de outro aplicativo:
///
/// - `padding(.horizontal, 20)` — o recuo do corpo da 04 (`EventWindow`,
///   linhas 176, 215 e 233).
/// - `padding(.vertical, 14)` — o `padding(.top, 14)` do bloco de lá (linha
///   216), aplicado em cima e embaixo porque aqui a linha se repete e precisa
///   respirar dos dois lados.
/// - 12,5pt sans no endereço — o corpo de valor da 04 (linha 264) e o mesmo da
///   linha da conta na lateral (`FolderSidebar`).
/// - 11,5pt na linha de estado — o corpo miúdo da 04 (linha 192, lá em mono).
///
/// O que **não** vem de lugar nenhum, e fica registrado como escolha: o
/// `spacing: 10` entre o chip e o texto (a lateral usa 8; aqui o chip divide a
/// linha com dois botões, e 8 os encostava) e o `spacing: 4` entre endereço e
/// estado, que é o menor respiro em que as duas linhas não leem como uma só.
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
                    // O realce segue `isFailing`, e não `error`: a mesma razão
                    // pela qual as ações seguem — uma conta que voltou do banco
                    // em erro tem a frase do erro, e a frase do erro é escrita
                    // no realce.
                    .foregroundStyle(AccountsCopy.isFailing(status) ? theme.accent.color : theme.ink3.color)
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

    /// Não é `private`: `AccountsWindowTests` chama diretamente para provar
    /// que "Ver o roteiro" não cai no mesmo `onReconnect` de "Reconectar" —
    /// ver `verORoteiroNaoReconecta`.
    func execute(_ acao: AccountRowAction, on accountID: String) {
        switch acao {
        case .reconnect: onReconnect(accountID)
        case .retry: onRetry(accountID)
        // Abre o arquivo direto — não passa pelo `model`, porque não há carga
        // nenhuma para refazer aqui, só um roteiro para ler.
        case .openRoteiro: AccountsDocs.open(AccountsDocs.oauthGoogle)
        case .remove: onRemove(accountID)
        }
    }
}
