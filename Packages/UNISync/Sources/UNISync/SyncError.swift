import Foundation

/// O único tipo de erro que sai do `UNISync`.
///
/// Único de propósito: toda superfície que mostra uma conta mostra o erro dela
/// com uma ação, e uma superfície só consegue fazer isso se souber a lista
/// inteira de coisas que podem dar errado. Um `Error` opaco vindo do
/// `URLSession` ou do `NIOSSL` obrigaria a UI a escrever "algo deu errado" —
/// que é erro engolido com boa apresentação.
///
/// `LocalizedError` não é enfeite: `MailStore.load()` grava
/// `error.localizedDescription` em `loadError`, e sem esta conformidade o
/// Foundation devolveria "The operation couldn’t be completed."
/// `Codable` também não: a falha que **para** a fila de saída de uma conta
/// precisa sobreviver ao app fechar — senão a abertura seguinte encontra as
/// linhas `falhou` no banco e não tem como dizer por quê (ver a coluna
/// `outbox.lastError`, da migração v7). Guardar só a frase bastaria para a
/// linha da conta, mas não para o **botão**: `AccountsCopy.actions(for:)` lê o
/// caso do erro para decidir entre "Reconectar" e "Tentar de novo", e uma
/// autorização revogada que voltasse do banco como texto ofereceria a ação
/// errada. O `Codable` é sintetizado — todo valor associado (`String`, `Int`,
/// `Int32`) já conforma.
public enum SyncError: Error, Sendable, Hashable, Codable, LocalizedError {
    /// Não chegou ao servidor: sem rota, tempo esgotado, DNS.
    case rede(String)
    /// Chegou, mas o TLS não fechou: certificado, versão, `STARTTLS` recusado.
    case tls(String)
    /// O servidor entendeu e recusou as credenciais.
    case autenticacao
    /// O usuário negou o consentimento, ou revogou o acesso depois.
    case autorizacaoRevogada
    /// O provedor pediu para desacelerar (HTTP 429, `[THROTTLED]` no IMAP).
    case quota
    /// O servidor respondeu com falha própria.
    case servidor(codigo: Int, mensagem: String)
    /// O servidor respondeu **pedindo que se tente de novo**: caixa ocupada,
    /// carga momentânea, greylisting.
    ///
    /// Caso próprio, e não um `.servidor` com o código dentro, por causa de uma
    /// colisão concreta: `OutboxExecutor.ehPermanente` lê o número de
    /// `.servidor` como código HTTP, e todo `4xx` do SMTP — que por definição
    /// do RFC 5321 é temporário — cairia na faixa que ele trata como pedido
    /// malformado e pararia a fila da conta. Um greylisting, que é o caso mais
    /// comum de primeira entrega a um domínio novo, pararia o envio para
    /// sempre em vez de esperar os cinco minutos que ele pede.
    case transitorio(String)
    /// O servidor recusou **de vez**: endereço que não existe, mensagem grande
    /// demais, relay negado.
    ///
    /// O par de `.transitorio`, e pelo mesmo motivo de existir: no SMTP o
    /// significado dos dígitos é o **inverso** do HTTP — `5yz` é definitivo
    /// ("essa caixa não existe") e `4yz` é temporário. Guardá-los em
    /// `.servidor` faria os dois serem lidos ao contrário: um endereço
    /// digitado errado seria repetido para sempre, com recuo, sem nunca
    /// aparecer para quem podia corrigi-lo.
    case recusado(String)
    /// O Keychain recusou. `status` é o `OSStatus` cru, para o relato ter o que
    /// procurar; a mensagem já vem traduzida.
    case keychain(status: Int32)
    /// Falta o OAuth Client ID do Google no bundle. Ver `docs/oauth-google.md`.
    case semClientID
    /// A resposta chegou e não dá para entender — JSON fora do contrato,
    /// `BAD` do IMAP, redirect sem `code` nem `error`.
    case resposta(String)
    /// Abrir ou migrar o banco local falhou — arquivo corrompido, disco
    /// cheio, permissão de sandbox negada. Caso próprio, e não `.resposta`:
    /// aquele é para respostas de servidor que não fazem sentido, e isto
    /// aqui nunca viu rede nenhuma.
    case banco(String)
    /// A reautorização voltou com **outra conta**.
    ///
    /// Caso próprio, e não `.autenticacao`, porque não há nada de errado com a
    /// credencial: ela é boa, é de outra pessoa. Reconectar existe para
    /// devolver a credencial da conta que já está aqui, e trocar a identidade
    /// dela em silêncio faria a caixa da pessoa passar a mostrar as mensagens
    /// de outra — com o banco, a fila de saída e as preferências da primeira
    /// pendurados na segunda.
    case contaDiferente(esperado: String, recebido: String)

    /// A frase que o usuário lê. Uma por caso, nenhuma genérica: "erro de
    /// rede" e "senha recusada" pedem ações diferentes, e uma frase só para as
    /// duas manda a pessoa tentar a coisa errada.
    public var mensagem: String {
        switch self {
        case .rede(let detalhe):
            "Não foi possível falar com o servidor: \(detalhe). Verifique a conexão e tente de novo."
        case .tls(let detalhe):
            "A conexão segura falhou: \(detalhe). Confira a porta e a forma de TLS da conta."
        case .autenticacao:
            "O servidor recusou o endereço ou a senha. Em provedores com verificação em duas etapas, use uma senha de app."
        case .autorizacaoRevogada:
            // A frase fala em **reconectar para autorizar**, e não em
            // "revogada" e ponto, porque a causa mais provável hoje não é
            // revogação nenhuma: é uma conta autorizada com o escopo antigo
            // (`gmail.modify`), que não cobre o apagamento definitivo. As duas
            // pedem a mesma ação — passar pela tela de consentimento de novo —
            // e a frase que só falava em revogação mandava a pessoa procurar
            // um acesso removido que ela nunca removeu.
            "Reconecte a conta para autorizar o acesso. Se a conta é antiga, ela foi autorizada com um escopo que não cobre apagar mensagens — reconectar resolve."
        case .quota:
            "O provedor pediu para desacelerar. A carga continua sozinha em instantes."
        case .servidor(let codigo, let mensagem):
            "O servidor respondeu \(codigo): \(mensagem)."
        case .transitorio(let detalhe):
            "O servidor pediu para tentar mais tarde: \(detalhe). A fila tenta sozinha."
        case .recusado(let detalhe):
            "O servidor recusou a mensagem: \(detalhe)."
        case .keychain(let status):
            "Não foi possível guardar o segredo no Keychain (código \(status))."
        case .semClientID:
            "Falta o OAuth Client ID do Google. Siga docs/oauth-google.md e rode xcodegen generate."
        case .resposta(let detalhe):
            "Resposta inesperada do servidor: \(detalhe)."
        case .banco(let detalhe):
            "Não foi possível abrir o banco local: \(detalhe)."
        case .contaDiferente(let esperado, let recebido):
            """
            Você entrou como \(recebido), e esta conta é \(esperado). \
            Reconectar refaz a autorização desta conta — para conectar \(recebido), \
            adicione uma conta nova.
            """
        }
    }

    /// Esta falha se resolve **refazendo a autorização desta conta**?
    ///
    /// A distinção que este predicado guarda é a que separa uma faixa de
    /// atenção útil de uma inútil: credencial recusada ou revogada é problema
    /// da **sessão**, e reconectar a resolve; falta de Client ID é problema do
    /// **aplicativo**, e um botão "Reconectar" ali abriria um consentimento sem
    /// nada com que se identificar — foi exatamente a tela que o dono viu, e
    /// nela a saída é o roteiro, não o botão. Rede, TLS e quota passam sozinhas
    /// e pedem "Tentar de novo".
    ///
    /// Aqui, e não dentro de `AccountsCopy`, porque quem sabe o que cada caso
    /// significa é quem os define: uma segunda leitura na camada de janela
    /// divergiria desta no primeiro caso novo.
    public var pedeReconexao: Bool {
        switch self {
        case .autenticacao, .autorizacaoRevogada: true
        default: false
        }
    }

    public var errorDescription: String? { mensagem }
}
