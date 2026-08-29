import Foundation

/// Os remetentes de quem as imagens remotas podem carregar sozinhas.
///
/// ## O bloqueio fica; o que faltava era a memória
///
/// "Toda hora tenho que clicar em Carregar, mesmo em remetente confiável." O
/// bloqueio por padrão está certo e não sai: a imagem remota de um email é o
/// pixel de rastreio, e carregá-la avisa o remetente de que a mensagem foi
/// aberta, quando e de onde. O que faltava era a pessoa poder dizer "deste
/// aqui, sempre" **uma vez** — e o app lembrar.
///
/// ## Por endereço, não por domínio
///
/// A confiança é guardada e conferida pelo **endereço inteiro**
/// (`noreply@calendly.com`), nunca pelo domínio.
///
/// O argumento a favor do domínio é real: um remetente como o Calendly manda
/// de vários prefixos (`noreply@`, `notifications@`, `no-reply@`), e confiar
/// só num deles faz a faixa voltar na próxima mensagem. Perde mesmo assim, por
/// dois motivos.
///
/// 1. **O que a pessoa aprovou é o que ela leu.** O rótulo diz "Sempre
///    carregar de noreply@calendly.com". Gravar `calendly.com` seria conceder
///    mais do que o botão prometeu — e conceder para endereços que ela nunca
///    viu.
/// 2. **`From` é falsificável e barato.** Sem DKIM/SPF conferidos (e este app
///    ainda não os confere), um domínio inteiro liberado é uma porta larga:
///    basta escrever `qualquer-coisa@calendly.com` no cabeçalho para herdar a
///    confiança. O endereço exato reduz a porta ao que foi de fato aprovado.
///
/// O preço é um clique a mais por prefixo novo, e ele é pequeno: a lista
/// cresce sozinha com o uso, e cada linha dela é uma decisão que alguém tomou
/// olhando o endereço.
///
/// ## Da pessoa, não da conta
///
/// Sem chave estrangeira para `account`, pelo mesmo raciocínio da tabela de
/// agenda: confiar no Calendly é uma decisão sobre **o remetente**, e ela vale
/// para ele em qualquer caixa. Sair de uma conta não desfaz o que a pessoa
/// disse sobre quem lhe escreve.
public protocol SenderTrusting: Sendable {
    /// "Deste remetente, sempre." O endereço chega como estiver escrito; quem
    /// normaliza é a implementação — ver `SenderTrust.normalize`.
    func trustSender(_ address: String) throws

    /// O contrário, e ele **precisa** existir: uma confiança sem revogação é
    /// um beco. É o "Rever" da faixa.
    func revokeSenderTrust(_ address: String) throws

    /// Todos os endereços confiados, já normalizados.
    func trustedSenders() throws -> Set<String>
}

public enum SenderTrust {
    /// O endereço na forma em que ele é gravado e comparado.
    ///
    /// Minúsculas e sem espaço nas pontas. A parte local de um endereço é,
    /// pelo RFC 5321, sensível a maiúsculas — na prática nenhum servidor do
    /// mundo real trata `Noreply@` e `noreply@` como pessoas diferentes, e
    /// tratá-las assim aqui teria um custo certo: o mesmo remetente entraria
    /// duas vezes na lista e a faixa voltaria a aparecer para quem já tinha
    /// confiado nele.
    public static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
