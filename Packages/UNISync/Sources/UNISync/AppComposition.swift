import Foundation
import GRDB
import NIOCore
import NIOPosix
import UNICore
import os

/// Quem monta o mundo do `UNISync` para o app.
///
/// A decisão que ela toma é a do critério de aceite do Marco 2: **sem conta
/// conectada, o app continua nas fixtures.** Isso não é comodidade — é o que
/// faz as capturas e os ensaios do Marco 1 continuarem valendo, e é o que
/// garante que instalar esta versão não deixa ninguém com a tela vazia.
///
/// Ela mora aqui, no `UNISync`, e não no alvo do app, por uma razão simples: o
/// alvo do app não tem testes, e esta é a decisão mais consequente do marco.
/// No `App/` fica só a fiação — `@State`, cenas, menu.
public struct AppComposition: Sendable {
    /// O banco do contêiner. Nulo quando ele não pôde ser aberto — e nesse
    /// caso o app **abre mesmo assim**, nas fixtures.
    public let database: SyncDatabase?
    /// Nulo pelo mesmo motivo do banco: sem banco não há o que dirigir. A
    /// janela de Contas mostra o erro em vez de uma tabela vazia.
    public let director: AccountDirector?
    /// A fonte que a UI lê. `DatabaseMailSource` quando há pelo menos uma
    /// conta; `InMemoryMailSource.fixtures` quando não há.
    public let source: any MailSource
    /// Falha de configuração que o app **mostra** em vez de esconder: banco
    /// que não abriu, client ID que falta. Nunca fatal.
    public let configError: SyncError?

    private static let log = Logger(subsystem: "com.okamiops.okamiuni", category: "AppComposition")

    /// Monta tudo.
    ///
    /// `databasePath` nulo usa `SyncDatabase.defaultPath()`, que **cria o
    /// diretório-pai** antes de devolver o caminho — a lição da Task 5:
    /// `SyncDatabase.init(path:)` abre o arquivo e migra, e não cria pasta
    /// nenhuma. Quem passa um caminho explícito (os testes, e só eles) é dono
    /// do diretório dele; é justamente por isso que um caminho impossível cai
    /// no ramo das fixtures em vez de ser "consertado" por baixo do pano.
    ///
    /// `@MainActor` não é decoração: `WebAuthorizationPresenter` apresenta a
    /// sessão de autorização do sistema e por isso nasce no ator principal, e
    /// `AccountsModel` — quem consome o diretor — também é dele. A composição
    /// acontece no `init` do `App`, que já é o ator principal; dizer isso no
    /// tipo é o que troca um aviso de concorrência por uma garantia.
    @MainActor
    public static func make(databasePath: String? = nil, bundle: Bundle = .main) -> AppComposition {
        let banco: SyncDatabase
        do {
            banco = try SyncDatabase(path: try databasePath ?? SyncDatabase.defaultPath())
        } catch {
            // Banco que não abre não pode impedir o app de abrir: as fixtures
            // seguram a tela e a janela de Contas explica o que houve.
            let falha = error as? SyncError
                ?? .banco("Não foi possível abrir o banco: \(error.localizedDescription)")
            log.error("Banco não abriu: \(falha.mensagem, privacy: .public)")
            return AppComposition(
                database: nil, director: nil,
                source: InMemoryMailSource.fixtures, configError: falha
            )
        }

        let cofre = KeychainSecretStore()
        var erro: SyncError?
        var auth: GoogleAuth?
        do {
            auth = GoogleAuth(
                config: try GoogleAuthConfig.fromBundle(bundle), session: .shared,
                secrets: cofre, presenter: WebAuthorizationPresenter()
            )
        } catch {
            // Sem client ID a rota Google não existe — e o app continua inteiro
            // pela rota IMAP. O erro vai para a janela de Contas, que é onde a
            // pessoa pode fazer alguma coisa com ele.
            erro = error as? SyncError ?? .semClientID
            log.notice("Rota Google indisponível: \(erro!.mensagem, privacy: .public)")
        }

        let director = AccountDirector(
            database: banco,
            secrets: cofre,
            auth: auth,
            session: .shared,
            // Duas threads: uma carga IMAP por vez é o que o `AccountDirector`
            // permite por conta, e duas contas carregando juntas é o caso real
            // de quem tem trabalho e pessoal.
            eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 2)
        )

        // Tem conta? Então o banco é a fonte. Não tem? Fixtures — e é isso que
        // mantém os ensaios e as capturas do Marco 1 idênticos.
        //
        // **A escolha não é feita aqui, e de propósito.** Decidi-la uma vez, na
        // abertura, faria a troca depender de reiniciar o app: a primeira conta
        // entraria e a tela continuaria nas fixtures, a última sairia e a tela
        // ficaria vazia. Quem acompanha o banco continuamente é a observação, e
        // é lá dentro que a pergunta "há conta?" é refeita a cada retrato — ver
        // `DatabaseMailSource.emptyFallback`. Assim é o `observe()` do
        // `MailStore` que troca a lista na tela, nos dois sentidos, sem
        // reinício.
        return AppComposition(
            database: banco,
            director: director,
            source: DatabaseMailSource(database: banco, emptyFallback: .fixtures),
            configError: erro
        )
    }
}
