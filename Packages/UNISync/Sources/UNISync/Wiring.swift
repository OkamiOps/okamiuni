import Foundation
import GRDB
import NIOIMAP

/// O espaço de nomes do pacote, e a prova de que as duas dependências novas
/// linkam.
///
/// `wiringCheck()` não é código de produção disfarçado: ele existe para a
/// Task 2 ter um verde que não depende de nenhuma decisão do produto. Se um dia
/// alguém o apagar e nada quebrar, ele terá cumprido o papel — mas até lá ele é
/// o primeiro a falhar quando uma atualização de GRDB ou de swift-nio-imap
/// muda de nome de produto.
public enum UNISync {
    public static func wiringCheck() -> String {
        _ = DatabaseQueue.self
        _ = MailboxName.self
        return "GRDB+NIOIMAP"
    }
}
