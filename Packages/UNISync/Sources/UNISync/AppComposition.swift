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
    /// Para onde o `MailStore` manda as seis mutações do Marco 3.
    /// `DatabaseCommandPort` quando o banco abriu; `nil` quando não — e
    /// nesse caso `MailStore` fica só em memória, como no Marco 1. Ao
    /// contrário de `source`, que troca sozinha entre banco e fixtures a
    /// cada retrato (ver `DatabaseMailSource.emptyFallback`), esta porta não
    /// precisa trocar: escrever no banco sem conta nenhuma cadastrada não
    /// tem para onde apontar (`accountID` não existiria), então o próprio
    /// `MailStore` nunca a chama nesse caso — não há mensagem para mutar.
    public let commandPort: MailCommandPort?
    /// Quem busca o corpo que a carga inicial não trouxe. `nil` quando o banco
    /// não abriu — e nesse caso a fonte são as fixtures, que já têm corpo.
    ///
    /// Ao contrário de `commandPort`, esta porta é **rede**: é a única do app
    /// cuja espera o leitor precisa mostrar na tela.
    public let bodyPort: BodyFetching?
    /// Quem leva a fila de saída ao servidor, uma conta por vez. Nulo pelo
    /// mesmo motivo do banco. Já vem **ligado**: a fila começa a andar ao
    /// abrir o app, que é o que faz uma ação feita offline chegar ao servidor
    /// assim que a rede volta, sem a pessoa ter de fazer nada.
    public let outbox: OutboxRunner?
    /// O aviso que a porta de escrita dá ao executor. Público porque a tarefa
    /// 3 (o `NWPathMonitor`) chama `notify` daqui.
    public let outboxSignal: OutboxSignal?
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
                source: InMemoryMailSource.fixtures, commandPort: nil, bodyPort: nil,
                outbox: nil, outboxSignal: nil, configError: falha
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

        // Duas threads: uma carga IMAP por vez é o que o `AccountDirector`
        // permite por conta, e duas contas carregando juntas é o caso real de
        // quem tem trabalho e pessoal. O mesmo grupo serve a fila de saída —
        // as conexões dela são igualmente uma por conta.
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let director = AccountDirector(
            database: banco,
            secrets: cofre,
            auth: auth,
            session: .shared,
            eventLoopGroup: grupo
        )

        let sinal = OutboxSignal()
        let fila = OutboxRunner(
            database: banco, secrets: cofre, auth: auth, session: .shared,
            eventLoopGroup: grupo, signal: sinal
        )
        // A fila começa a andar ao abrir. `Task` porque ligar os executores lê
        // o banco, e a composição é síncrona de propósito: o app não pode
        // esperar por I/O para desenhar a primeira janela.
        Task { await fila.start() }

        // Os corpos que uma versão anterior gravou crus são consertados na
        // abertura. Numa `Task` pela mesma razão que a fila, e por uma segunda:
        // ela toca o banco em lotes, e a primeira janela não pode esperar por
        // isso. Cada corpo consertado acorda a `ValueObservation` pelo caminho
        // normal, então a tela troca o `--fronteira` pelo texto sozinha,
        // enquanto a pessoa olha.
        //
        // Falhar aqui não pode custar a abertura do app: o pior caso é o corpo
        // continuar cru, que é exatamente o estado de antes desta tarefa.
        Task {
            do { _ = try await BodyRedecoding.run(banco) } catch {
                log.error("A re-decodificação dos corpos não terminou: \(error)")
            }
        }

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
            commandPort: DatabaseCommandPort(database: banco, signal: sinal),
            bodyPort: DatabaseBodyFetcher(
                database: banco, secrets: cofre, auth: auth,
                session: .shared, eventLoopGroup: grupo
            ),
            outbox: fila,
            outboxSignal: sinal,
            configError: erro
        )
    }
}
