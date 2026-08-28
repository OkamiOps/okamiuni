import Foundation
import GRDB
import NIOCore

/// O espaço de nomes do pacote, e a prova de que as dependências novas linkam.
///
/// `wiringCheck()` não é código de produção disfarçado: ele existe para a
/// Task 2 ter um verde que não depende de nenhuma decisão do produto. Se um dia
/// alguém o apagar e nada quebrar, ele terá cumprido o papel — mas até lá ele é
/// o primeiro a falhar quando uma atualização de GRDB ou de SwiftNIO muda de
/// nome de produto.
///
/// O nome mudou junto com a árvore: o `swift-nio-imap` saiu do pacote na
/// rodada de conserto 2 da Task 10 — ele não fazia mais trabalho nenhum no
/// caminho de dados —, e o SwiftNIO, que era carona da árvore dele, passou a
/// dependência direta.
public enum UNISync {
    public static func wiringCheck() -> String {
        _ = DatabaseQueue.self
        _ = ByteBuffer.self
        return "GRDB+NIO"
    }
}
