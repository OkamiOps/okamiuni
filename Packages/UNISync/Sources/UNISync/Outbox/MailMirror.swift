import Foundation
import UNICore

/// O espelho da triagem: para onde o executor da fila manda uma operação.
///
/// **Um método só, e de propósito.** O que varia entre Gmail e IMAP é o
/// vocabulário (rótulo × pasta, `batchModify` × `UID STORE`), não a lista de
/// operações — ela já está fechada em `MailOperation`. Um protocolo com seis
/// métodos obrigaria cada espelho a repetir a mesma distribuição por caso, e a
/// próxima operação do Marco 3 (o envio) entraria em dois lugares em vez de um.
///
/// As coordenadas chegam **prontas**, decodificadas do id pelo executor
/// (`MessageIdentity.parse`). O espelho não toca o banco: ele fala com o
/// servidor e mais nada. É isso que deixa o executor ser testado contra um
/// espelho falso sem rede, e os espelhos serem testados contra o servidor falso
/// sem banco.
public protocol MailMirror: Sendable {
    /// Aplica a operação no servidor. Lança `SyncError` — é o executor quem
    /// decide o que é transitório e o que para a fila.
    ///
    /// Devolve **onde a cópia do que saiu ficou**, e só o envio devolve alguma
    /// coisa: o `id` do Gmail que a `messages.send` criou, o `APPENDUID` que o
    /// IMAP carimbou. Todo o resto devolve `nil`, porque não gravou nada novo
    /// em lugar nenhum — mudou bandeira e pasta de mensagem que já existia.
    ///
    /// Por que a coordenada, e não um simples "deu certo": é ela que faz a
    /// linha de Enviadas gravada aqui ter **o mesmo id** que a sincronização
    /// daria à mesma mensagem quando a trouxer do servidor
    /// (`MessageIdentity.gmail`/`.imap`). Mesmo id, `save` é upsert, e a
    /// mensagem que você mandou não aparece duas vezes na sua caixa. Um id
    /// inventado aqui seria a duplicata garantida no ciclo seguinte.
    ///
    /// `nil` num envio é legítimo e quer dizer "saiu, mas não há cópia nossa
    /// para gravar": servidor sem `LITERAL+`, conta sem pasta de Enviadas, ou
    /// a reexecução que descobriu que a mensagem já estava lá.
    @discardableResult
    func apply(_ operation: MailOperation, targets: [MessageCoordinate]) async throws -> MessageCoordinate?
}

/// O nome da pasta/rótulo "Depois" no servidor. Uma constante só para os dois
/// espelhos, herdada de `FolderRoles` — o nome que a leitura procura tem de ser
/// o mesmo que a escrita cria, senão "Depois" feito aqui não volta como Depois.
public enum MirrorNames {
    public static let later = FolderRoles.laterFolderName

    /// O nome da pasta de arquivo, quando o servidor **não tem nenhuma**.
    ///
    /// A conta do dono (`marcos@okamiops.com`) tinha a fila parada em "A conta
    /// não tem pasta de arquivo no servidor, e arquivar precisa de uma": o
    /// `LIST` não trazia `\Archive` nem nada que a heurística de nome
    /// reconhecesse, e o espelho desistia. Desistir é a resposta errada — a
    /// pessoa mandou arquivar, e criar a pasta que falta é o que qualquer
    /// cliente faz.
    ///
    /// `"Archive"` em inglês, e sem prefixo nosso, de propósito: é o nome que o
    /// `SPECIAL-USE` do RFC 6154 nomeia, o que a maioria dos servidores usa por
    /// padrão, e — o que decide — o que `FolderRoles.role(specialUse:name:)` já
    /// lê de volta como `.archive`. Uma pasta "OkamiUNI/Arquivo" seria nossa e
    /// de mais ninguém: o webmail da pessoa mostraria as mensagens arquivadas
    /// num canto que só este app entende.
    public static let archive = "Archive"

    /// O mesmo para a lixeira, pela mesma razão e com o mesmo critério: é o
    /// nome do `\Trash` do RFC 6154, e `FolderRoles` o reconhece de volta.
    public static let trash = "Trash"
}
