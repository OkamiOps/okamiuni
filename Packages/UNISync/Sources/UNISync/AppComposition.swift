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
    /// Para onde o "Enviar" do composer manda a mensagem. É o **mesmo**
    /// `DatabaseCommandPort` de `commandPort`, e não uma segunda porta: quem
    /// enfileira uma triagem e quem enfileira um envio escrevem na mesma
    /// tabela, e duas instâncias dariam dois avisos ao executor por engano.
    public let sendPort: MailSendPort?
    /// Quem busca o corpo que a carga inicial não trouxe. `nil` quando o banco
    /// não abriu — e nesse caso a fonte são as fixtures, que já têm corpo.
    ///
    /// Ao contrário de `commandPort`, esta porta é **rede**: é a única do app
    /// cuja espera o leitor precisa mostrar na tela.
    public let bodyPort: BodyFetching?
    /// De onde vem o catálogo real de contatos — quem já mandou, recebeu ou
    /// entrou em cópia numa mensagem sincronizada. `nil` quando o banco não
    /// abriu, pela mesma razão de `bodyPort`: sem banco não há onde
    /// consultar, e `MailStore` fica com `Fixtures.contacts`.
    public let contactPort: ContactDirectoryPort?
    /// Onde os compromissos que a pessoa criou sobrevivem ao fechar o app.
    /// `nil` quando o banco não abriu — e nesse caso a agenda volta a ser de
    /// sessão, como no Marco 1, que é o pior caso honesto: sem disco não há
    /// onde guardar.
    ///
    /// Ao contrário de `commandPort`, esta porta vale **mesmo sem conta
    /// conectada**: um compromisso criado a partir de uma mensagem de exemplo
    /// continua sendo um compromisso que a pessoa criou, e a tabela da v5 não
    /// tem chave estrangeira para `account` justamente por isso.
    public let agendaPort: (any AgendaPersisting)?
    /// De quem as imagens remotas podem carregar sozinhas — o "sempre carregar
    /// deste remetente" da faixa do leitor. `nil` quando o banco não abriu, e
    /// aí ninguém é confiável: o bloqueio da M3-8 sem memória, que é o pior
    /// caso honesto.
    ///
    /// Vale **mesmo sem conta conectada**, como a agenda e pelo mesmo motivo:
    /// a confiança é sobre o remetente, não sobre a caixa — e a tabela da v6
    /// não tem chave estrangeira para `account` justamente por isso.
    public let trustPort: (any SenderTrusting)?
    /// Quem leva a fila de saída ao servidor, uma conta por vez. Nulo pelo
    /// mesmo motivo do banco. Já vem **ligado**: a fila começa a andar ao
    /// abrir o app, que é o que faz uma ação feita offline chegar ao servidor
    /// assim que a rede volta, sem a pessoa ter de fazer nada.
    public let outbox: OutboxRunner?
    /// O aviso que a porta de escrita dá ao executor. Público porque o
    /// `NetworkWatcher` chama `notifyAll` daqui quando a rede volta.
    public let outboxSignal: OutboxSignal?
    /// Quem traz do servidor o que chegou depois da carga inicial, uma conta
    /// por vez. Já vem **ligado**, pela mesma razão que a fila: sincronizar é
    /// comportamento do app aberto, não um botão.
    public let sync: SyncRunner?
    /// Quem repara que a rede voltou e acorda os dois — a sincronização e a
    /// fila. Nulo quando não há banco, como todo o resto.
    public let network: NetworkWatcher?
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
                source: InMemoryMailSource.fixtures, commandPort: nil, sendPort: nil, bodyPort: nil,
                contactPort: nil, agendaPort: nil, trustPort: nil,
                outbox: nil, outboxSignal: nil, sync: nil, network: nil, configError: falha
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
        // O erro da fila e o do ciclo passam a **chegar à janela**: os dois
        // recebiam um relato que caía num no-op, e uma conta com a credencial
        // recusada aparecia na lista como se estivesse bem.
        let relata: @Sendable (String, SyncError?) -> Void = { conta, erro in
            Task { await director.report(accountID: conta, error: erro) }
        }
        let fila = OutboxRunner(
            database: banco, secrets: cofre, auth: auth, session: .shared,
            eventLoopGroup: grupo, signal: sinal, report: relata
        )
        // A fila começa a andar ao abrir. `Task` porque ligar os executores lê
        // o banco, e a composição é síncrona de propósito: o app não pode
        // esperar por I/O para desenhar a primeira janela. E ela segue o
        // diretor: conta adicionada com o app aberto ganha executor na hora —
        // sem isso, arquivar na conta nova enfileirava para sempre.
        Task {
            await fila.start()
            await fila.follow(director.statuses())
        }

        // A sincronização contínua. Ela não lê a lista de contas por conta
        // própria: assina o diretor, e é ele quem diz quem entrou, quem saiu e
        // quem parou de autenticar.
        let sincronizacao = SyncRunner(
            database: banco, secrets: cofre, auth: auth, session: .shared,
            eventLoopGroup: grupo, director: director, report: relata
        )
        Task { await sincronizacao.start() }

        // E a rede: quando o caminho volta, os dois lados andam na hora em vez
        // de esperar o próximo minuto.
        let rede = NetworkWatcher {
            await sincronizacao.wakeAll()
            sinal.notifyAll()
        }
        Task { await rede.start() }

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
        // Uma porta só para as duas coisas: a triagem e o envio escrevem na
        // mesma fila, e duas instâncias avisariam o executor duas vezes.
        let porta = DatabaseCommandPort(database: banco, signal: sinal)
        return AppComposition(
            database: banco,
            director: director,
            source: DatabaseMailSource(database: banco, emptyFallback: .fixtures),
            commandPort: porta,
            sendPort: porta,
            bodyPort: DatabaseBodyFetcher(
                database: banco, secrets: cofre, auth: auth,
                session: .shared, eventLoopGroup: grupo
            ),
            contactPort: DatabaseContactDirectory(database: banco),
            agendaPort: DatabaseAgendaStore(database: banco),
            trustPort: DatabaseTrustedSenderStore(database: banco),
            outbox: fila,
            outboxSignal: sinal,
            sync: sincronizacao,
            network: rede,
            configError: erro
        )
    }
}
