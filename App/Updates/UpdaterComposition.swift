import Foundation
import UNIShell
import UNISync

/// Quem decide se este build tem atualizador.
///
/// A decisão é uma só e é a razão de o tipo existir: **em Debug não há
/// atualizador nenhum.** Um build de desenvolvimento que aceitasse um release
/// do appcast se substituiria pela versão publicada no meio do trabalho — o
/// `.app` do `/tmp` daria lugar ao release assinado, e o que estava sendo
/// escrito naquela sessão iria embora sem aviso. Não é um risco teórico: o
/// `MARKETING_VERSION` do build local é sempre igual ou menor que o do último
/// release.
///
/// Por isso o `#if DEBUG` fica aqui, num lugar só, e não espalhado pela
/// interface: o resto do app recebe `nil` e já sabe o que fazer com isso — o
/// botão da lateral não aparece e o cartão de Ajustes diz a versão em uso e por
/// que não há atualização.
enum UpdaterComposition {

    /// O atualizador do app, ou `nil` em Debug.
    ///
    /// - Parameter database: o banco do `UNISync`, de onde sai a sonda da fila
    ///   de saída. `nil` quando o banco não abriu — e aí "Instalar e reabrir"
    ///   instala sem esperar, porque sem banco não há fila para esperar.
    @MainActor
    static func make(database: SyncDatabase?) -> UpdateController? {
        #if DEBUG
        return nil
        #else
        let engine = SparkleUpdateEngine(
            pendingSends: database.map(PendingSendProbe.init(database:))
        )
        return UpdateController(engine: engine)
        #endif
    }
}
