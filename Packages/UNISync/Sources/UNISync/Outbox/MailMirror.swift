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
    func apply(_ operation: MailOperation, targets: [MessageCoordinate]) async throws
}

/// O nome da pasta/rótulo "Depois" no servidor. Uma constante só para os dois
/// espelhos, herdada de `FolderRoles` — o nome que a leitura procura tem de ser
/// o mesmo que a escrita cria, senão "Depois" feito aqui não volta como Depois.
public enum MirrorNames {
    public static let later = FolderRoles.laterFolderName
}
