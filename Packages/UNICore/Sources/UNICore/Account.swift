import Foundation

/// Onde e como falar IMAP com um servidor.
///
/// Um tipo próprio, e não três campos soltos em `Account`, porque os três só
/// fazem sentido juntos: porta sem host não liga em lugar nenhum, e "usa TLS"
/// sem porta não diz se é 993 (TLS desde o primeiro byte) ou 143 com
/// `STARTTLS`. Nulo em `Account.imap` significa "esta conta não fala IMAP" —
/// uma conta Google recém-conectada, por exemplo.
public struct ImapEndpoint: Sendable, Hashable {
    /// Como o TLS entra. Não é preferência: é o protocolo do servidor.
    public enum Security: String, Sendable, Hashable, CaseIterable {
        /// TLS implícito, desde o primeiro byte. Porta canônica 993.
        case tls
        /// Conexão em claro que sobe para TLS com `STARTTLS`. Porta 143.
        case startTLS
    }

    public let host: String
    public let port: Int
    public let security: Security

    public init(host: String, port: Int, security: Security) {
        self.host = host
        self.port = port
        self.security = security
    }
}

public struct Account: Sendable, Hashable, Identifiable {
    /// Como o app conversa com o servidor — não quem é o provedor.
    ///
    /// `imap` é o caso geral e cobre qualquer provedor em qualquer domínio.
    /// `gmail` e `microsoft` existem só onde a API nativa rende sync melhor;
    /// uma conta desses dois continua funcionando por `imap`. Nunca tratar
    /// `imap` como exceção nem presumir que a lista de provedores é fechada.
    public enum Provider: String, Sendable, CaseIterable {
        case imap, gmail, microsoft
    }

    /// Em que pé a conta está — o que a lateral e a janela de Contas mostram.
    ///
    /// `erroDeAutenticacao` é o estado que o refresh de token falhado e o
    /// `LOGIN` recusado produzem. Ele existe como **estado da conta**, e não
    /// como um alerta passageiro, porque a conta continua na lista com as
    /// mensagens que já baixou: o que ela perdeu foi o direito de baixar mais.
    /// Toda superfície que mostra uma conta neste estado tem de oferecer
    /// reconectar — conta parada sem explicação é a versão de dados do botão
    /// mudo.
    public enum State: String, Sendable, Hashable, CaseIterable {
        case ativa
        case carregando
        case erroDeAutenticacao
    }

    public let id: String
    public let address: String
    public let displayName: String
    public let provider: Provider

    /// O nome do provedor que os chips mostram em versalete: "zoho", "gmail",
    /// "hostinger", "icloud".
    ///
    /// **É dado da conta, não a chave interna.** Já foi `var host { id }`, e a
    /// janela mostrava HOST onde o design mostra HOSTINGER — o `id` é o que o
    /// app usa para casar mensagem com conta, e não tem por que coincidir com
    /// o nome que o usuário lê. Nada de tabela dos quatro exemplos aqui:
    /// qualquer conta, de qualquer provedor, traz o seu.
    ///
    /// Quem tem pouca largura encurta **ao desenhar** (`HostMark.rail`), nunca
    /// guardando uma segunda versão curta do nome.
    public let host: String

    /// Cor em temas claros, já convertida para sRGB.
    public let tintLightHex: String
    /// Cor em temas escuros, já convertida para sRGB.
    public let tintDarkHex: String

    /// A assinatura desta conta em texto simples, preservada por
    /// compatibilidade com quem ainda não entende HTML.
    ///
    /// **É da conta, não do app.** O design escreve isso na linha "De" da tela
    /// 06: *"a assinatura muda com a conta"*. Uma assinatura só, guardada em
    /// preferência global, contradiria a única frase que o protótipo tem sobre
    /// o assunto — quem escreve pela conta do trabalho e pela pessoal assina
    /// diferente, e é justamente por isso que a legenda está ali.
    ///
    /// Vazia é ausência de assinatura, não uma assinatura em branco: o botão
    /// fica desabilitado e diz por quê, em vez de inserir duas linhas vazias.
    public let signature: String

    /// A assinatura estruturada que o composer/transportador pode colocar em
    /// `text/plain`, `text/html` e recursos `cid:`. `signature` acima continua
    /// sendo a alternativa em texto e nunca vira uma segunda fonte de verdade.
    public let emailSignature: EmailSignature

    /// Nulo para contas que não falam IMAP (uma conta Google, por exemplo).
    public let imap: ImapEndpoint?

    /// O estado corrente. Default `.ativa`: as fixtures do Marco 1 nasceram
    /// sem estado nenhum e continuam significando "funcionando".
    public let state: State

    /// Quando a última sincronização terminou. Nulo é "nunca sincronizou" —
    /// que é o que a janela mostra como "ainda não sincronizada", em vez de
    /// inventar uma data.
    ///
    /// `Date` aqui não fere a regra de fuso: isto é um **instante**, não um
    /// horário de parede. Quem escreve "às 14:32" formata na borda, com o
    /// `Calendar` de quem está lendo.
    public let lastSyncedAt: Date?

    /// Endereços extras pelos quais esta conta envia. O principal continua
    /// em `address` e não se repete aqui.
    public let sendAliases: [SendAlias]

    public init(
        id: String, address: String, displayName: String,
        provider: Provider, host: String, tintLightHex: String, tintDarkHex: String,
        signature: String = "",
        emailSignature: EmailSignature? = nil,
        imap: ImapEndpoint? = nil,
        state: State = .ativa,
        lastSyncedAt: Date? = nil,
        sendAliases: [SendAlias] = []
    ) {
        self.id = id
        self.address = address
        self.displayName = displayName
        self.provider = provider
        self.host = host
        self.tintLightHex = tintLightHex
        self.tintDarkHex = tintDarkHex
        let resolvedSignature = emailSignature ?? EmailSignature(legacyText: signature)
        self.signature = resolvedSignature.plainText
        self.emailSignature = resolvedSignature
        self.imap = imap
        self.state = state
        self.lastSyncedAt = lastSyncedAt
        self.sendAliases = sendAliases
    }

    /// Retorna a cor apropriada para o tema.
    public func tint(isDark: Bool) -> String {
        isDark ? tintDarkHex : tintLightHex
    }

    /// A mesma conta noutro estado.
    public func withState(_ state: State) -> Account { copy(state: state) }

    /// A mesma conta com outro carimbo de sincronização.
    public func withLastSynced(_ date: Date?) -> Account {
        copy(lastSyncedAt: .some(date))
    }

    /// A mesma conta com outro endpoint IMAP (ou nenhum).
    public func withImap(_ endpoint: ImapEndpoint?) -> Account {
        copy(imap: .some(endpoint))
    }

    /// A mesma conta com outra assinatura, sem perder o estado corrente.
    public func withSignature(_ signature: String) -> Account {
        copy(signature: signature)
    }

    /// A mesma conta com uma assinatura rica. A versão textual dela continua
    /// disponível em `signature` para os consumidores legados.
    public func withEmailSignature(_ signature: EmailSignature) -> Account {
        copy(emailSignature: signature)
    }

    /// A mesma conta com outra identidade cromática local.
    public func withTint(lightHex: String, darkHex: String) -> Account {
        copy(tintLightHex: lightHex, tintDarkHex: darkHex)
    }

    /// A mesma conta com outra lista de aliases. O endereço principal não
    /// entra nesta lista — ele já é `address`.
    public func withSendAliases(_ aliases: [SendAlias]) -> Account {
        copy(sendAliases: aliases)
    }

    /// Remetentes que o composer oferece: o endereço da conta, depois os
    /// aliases, sem duplicata.
    public var sendIdentities: [SendIdentity] {
        var seen: Set<String> = []
        var list: [SendIdentity] = []
        func add(_ address: String, name: String, primary: Bool) {
            let key = address.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            let shown = name.trimmingCharacters(in: .whitespacesAndNewlines)
            list.append(SendIdentity(
                accountID: id,
                address: address,
                displayName: shown.isEmpty ? displayName : shown,
                isPrimary: primary
            ))
        }
        add(address, name: displayName, primary: true)
        for alias in sendAliases.sorted(by: {
            $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending
        }) {
            add(alias.address, name: alias.displayName, primary: false)
        }
        return list
    }

    /// O From pré-selecionado: o alias marcado como padrão, senão o principal.
    public var defaultSendAddress: String {
        sendAliases.first(where: \.isDefault)?.address ?? address
    }

    /// O único lugar que reconstrói uma `Account`.
    ///
    /// Onze campos, três deles com default no `init`: reconstruir à mão em
    /// cada chamador é a mesma armadilha que `Message.copy` já pagou — o campo
    /// esquecido **compila** e vira uma assinatura sumida ou uma conta que
    /// voltou a "ativa" sozinha. Acrescentar campo ao modelo quebra este
    /// arquivo, que é onde se quer que quebre.
    ///
    /// Os dois opcionais entram como `String??`/`Date??` para "não mexer"
    /// (`nil`) ser distinguível de "apagar" (`.some(nil)`).
    private func copy(
        state: State? = nil,
        imap: ImapEndpoint?? = nil,
        lastSyncedAt: Date?? = nil,
        tintLightHex: String? = nil,
        tintDarkHex: String? = nil,
        signature: String? = nil,
        emailSignature: EmailSignature? = nil,
        sendAliases: [SendAlias]? = nil
    ) -> Account {
        let resolvedSignature = emailSignature
            ?? signature.map(EmailSignature.init(legacyText:))
            ?? self.emailSignature
        return Account(
            id: id, address: address, displayName: displayName,
            provider: provider, host: host,
            tintLightHex: tintLightHex ?? self.tintLightHex,
            tintDarkHex: tintDarkHex ?? self.tintDarkHex,
            signature: resolvedSignature.plainText,
            emailSignature: resolvedSignature,
            imap: imap ?? self.imap,
            state: state ?? self.state,
            lastSyncedAt: lastSyncedAt ?? self.lastSyncedAt,
            sendAliases: sendAliases ?? self.sendAliases
        )
    }
}
