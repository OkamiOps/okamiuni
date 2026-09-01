import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

@Suite("Estado da caixa na barra de busca")
struct MailboxChromeStatusTests {

    @Test("Sem conta, a barra não inventa andamento e o recarregar não tem o que fazer")
    func emptyWhenThereAreNoAccounts() {
        let status = MailboxChromeStatus.from([])
        #expect(status == .empty)
        #expect(status.canReload == false)
        #expect(status.isBusy == false)
        #expect(status.label == "Nenhuma conta para sincronizar")
    }

    @Test("Carga inicial com total conhecido vira porcentagem honesta")
    func initialLoadUsesCombinedProgress() {
        let status = MailboxChromeStatus.from([
            conta(id: "a", state: .carregando, progress: LoadProgress(accountID: "a", done: 250, total: 1_000)),
            conta(id: "b", state: .carregando, progress: LoadProgress(accountID: "b", done: 250, total: 1_000)),
        ])
        #expect(status == .loading(fraction: 0.25))
        #expect(status.isBusy)
        #expect(status.canReload)
        #expect(status.label == "Carregando a caixa… 25%")
    }

    @Test("Carga sem total não finge 0%")
    func unknownTotalIsIndeterminate() {
        let status = MailboxChromeStatus.from([
            conta(id: "a", state: .carregando, progress: nil),
        ])
        #expect(status == .loading(fraction: nil))
        #expect(status.label == "Sincronizando a caixa…")
    }

    @Test("Ciclo incremental em curso conta como carregando, mesmo com a conta ativa")
    func incrementalCycleIsBusy() {
        let status = MailboxChromeStatus.from([
            conta(id: "a", state: .ativa, isSyncing: true),
        ])
        #expect(status == .loading(fraction: nil))
        #expect(status.isBusy)
        #expect(status.label == "Sincronizando a caixa…")
    }

    @Test("Carregar ganha de falhar: o andamento de uma conta não some atrás do erro de outra")
    func loadingBeatsFailure() {
        let status = MailboxChromeStatus.from([
            conta(id: "a", state: .carregando, progress: LoadProgress(accountID: "a", done: 1, total: 2)),
            conta(id: "b", state: .erroDeAutenticacao, error: .autenticacao),
        ])
        #expect(status == .loading(fraction: 0.5))
    }

    @Test("Conta em erro, sem carga, mostra a causa")
    func failedShowsTheCause() {
        let status = MailboxChromeStatus.from([
            conta(id: "a", state: .erroDeAutenticacao, error: .autenticacao),
        ])
        #expect(status == .failed(SyncError.autenticacao.mensagem))
        #expect(status.isBusy == false)
        #expect(status.canReload)
    }

    @Test("Contas ativas e quietas são caixa atualizada")
    func readyWhenActiveAndIdle() {
        let status = MailboxChromeStatus.from([
            conta(id: "a", state: .ativa, lastSyncedAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
        #expect(status == .ready)
        #expect(status.label == "Caixa atualizada")
        #expect(status.canReload)
        #expect(status.isBusy == false)
    }

    @Test("A última sync vira 'há N min' ou 'às HH:mm'")
    func lastSyncedCaptionIsRelative() {
        let agora = Date(timeIntervalSince1970: 1_800_000_000)
        let quatroMin = agora.addingTimeInterval(-4 * 60)
        #expect(
            MailboxChromeStatus.lastSyncedCaption(
                from: [conta(id: "a", state: .ativa, lastSyncedAt: quatroMin)],
                now: agora
            ) == "há 4 min"
        )
        #expect(MailboxChromeStatus.relativeSync(agora, now: agora) == "agora")
    }

    @Test("Gmail Entrada 165 · aqui 162, e o que falta é clicável")
    func portraitComparesRemoteAndLocal() {
        let retrato = MailboxPortrait(
            remoteLabel: "Gmail Entrada",
            remoteCount: 165,
            localCount: 162,
            lastSyncedAt: nil,
            hasMore: false
        )
        #expect(retrato.countCaption == "Gmail Entrada 165 · aqui 162")
        #expect(retrato.gapCaption == "3 não estão no app")
        let um = MailboxPortrait(
            remoteLabel: "Gmail Entrada", remoteCount: 163, localCount: 162,
            lastSyncedAt: nil, hasMore: false
        )
        #expect(um.gapCaption == "1 não está no app")
        let ok = MailboxPortrait(
            remoteLabel: "Gmail Entrada", remoteCount: 162, localCount: 162,
            lastSyncedAt: nil, hasMore: false
        )
        #expect(ok.gapCaption == nil)
    }

    private func conta(
        id: String,
        state: Account.State,
        progress: LoadProgress? = nil,
        error: SyncError? = nil,
        lastSyncedAt: Date? = nil,
        isSyncing: Bool = false
    ) -> AccountStatus {
        AccountStatus(
            accountID: id, address: "\(id)@x.com", hostMark: "x",
            state: state, messageCount: 0, lastSyncedAt: lastSyncedAt,
            error: error, progress: progress, isSyncing: isSyncing
        )
    }
}
