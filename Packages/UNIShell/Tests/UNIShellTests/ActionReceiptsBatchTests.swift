import Foundation
import Testing
import UNICore
@testable import UNIShell

/// A leva desfazível: executar um cartão da gaveta (ou o "Arquivar e
/// aprender" da linha) produz **um** recibo, e o Desfazer dele desfaz
/// exatamente o que a leva fez — nem menos, nem a ação de outra pessoa que
/// estava na barra antes.
@Suite("A leva desfazível")
@MainActor
struct ActionReceiptsBatchTests {

    /// Uma porta de regra em memória, para o desfazer conjunto ter onde
    /// gravar e revogar.
    private final class RegrasEmMemoria: SenderRuling, @unchecked Sendable {
        private let lock = NSLock()
        private var regras: [String: SenderRule] = [:]
        func learnSender(_ address: String, neverPriority: Bool, at date: Date) throws {
            lock.lock(); defer { lock.unlock() }
            if neverPriority {
                regras[address] = SenderRule(address: address, createdAt: date)
            } else {
                regras[address] = nil
            }
        }
        func senderRules() throws -> [SenderRule] {
            lock.lock(); defer { lock.unlock() }
            return Array(regras.values)
        }
    }

    private func loja(_ mensagens: [Message]) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: DiaDoDono.contas, messages: mensagens, agenda: []
            ),
            senderRulePort: RegrasEmMemoria()
        )
        await store.load()
        return store
    }

    /// O cenário do C1: o cartão "13 emails vão para Arquivado" — aqui com
    /// três — arquiva os três e o Desfazer devolve os três.
    @Test("uma leva de três arquivamentos desfaz os três, e só eles")
    func aBatchOfThreeArchivesUndoesAllThree() async throws {
        let store = await loja([DiaDoDono.carol, DiaDoDono.resend, DiaDoDono.abacus, DiaDoDono.jack])
        let receipts = ActionReceipts()

        receipts.beginBatch()
        for id in ["carol", "resend", "abacus"] {
            #expect(
                receipts.intercept(.move(messageID: id, to: .archived), on: store, stamp: "14:32"),
                "a leva não interceptou o arquivamento de \(id)"
            )
        }
        let recibo = try #require(
            receipts.sealBatch(stamp: "14:32"), "a leva não selou recibo nenhum"
        )
        #expect(receipts.current?.id == recibo.id, "o recibo da leva não foi para a barra")
        for id in ["carol", "resend", "abacus"] {
            #expect(store.message(id)?.bucket == .archived, "\(id) não foi arquivada")
        }
        #expect(store.message("jack")?.bucket == .today)

        StoreCommand.run(recibo.undo, on: store)
        for id in ["carol", "resend", "abacus"] {
            #expect(store.message(id)?.bucket == .today, "\(id) não voltou")
        }
        #expect(store.message("jack")?.bucket == .today, "o Desfazer mexeu em quem não estava na leva")
    }

    /// O segundo cenário do C1: com um recibo de lixeira já de pé, o Desfazer
    /// do cartão desfaz **o cartão** — a mensagem apagada continua apagada.
    @Test("com um recibo de lixeira na barra, o Desfazer da leva não toca na lixeira")
    func aStandingTrashReceiptIsNeverTheCardsUndo() async throws {
        let store = await loja([DiaDoDono.carol, DiaDoDono.resend, DiaDoDono.jack])
        let receipts = ActionReceipts()

        // A pessoa acabou de apagar um email: o recibo da lixeira está de pé.
        #expect(receipts.intercept(.move(messageID: "jack", to: .trash), on: store, stamp: "14:30"))
        let daLixeira = try #require(receipts.current)

        receipts.beginBatch()
        _ = receipts.intercept(.move(messageID: "carol", to: .archived), on: store, stamp: "14:32")
        _ = receipts.intercept(.move(messageID: "resend", to: .archived), on: store, stamp: "14:32")
        let daLeva = try #require(receipts.sealBatch(stamp: "14:32"))

        #expect(daLeva.id != daLixeira.id, "a leva reaproveitou o recibo da lixeira")
        StoreCommand.run(daLeva.undo, on: store)
        #expect(store.message("jack")?.bucket == .trash, "o Desfazer da leva esvaziou a lixeira")
        #expect(store.message("carol")?.bucket == .today)
        #expect(store.message("resend")?.bucket == .today)
    }

    /// Uma leva sem volta (um bloco de agenda, por exemplo) **não** pode
    /// deixar o recibo de outra origem de pé: o cartão diria "Desfazer" e
    /// desfaria outra coisa.
    @Test("leva sem volta não herda o recibo de outra origem")
    func anUnundoableBatchNeverInheritsAForeignReceipt() async throws {
        let store = await loja([DiaDoDono.jack])
        let receipts = ActionReceipts()
        #expect(receipts.intercept(.move(messageID: "jack", to: .trash), on: store, stamp: "14:30"))
        #expect(receipts.current != nil)

        receipts.beginBatch()
        let recibo = receipts.sealBatch(undoable: false, stamp: "14:32")
        #expect(recibo == nil, "uma leva sem volta selou recibo")
        #expect(receipts.current == nil, "o recibo velho ficou de pé fingindo ser o da leva")
    }

    /// O I2: o par "Arquivar e aprender" é **um** recibo composto, e o
    /// endereço é comparado normalizado — `No-Reply@Abacus.AI` é o mesmo
    /// remetente de `no-reply@abacus.ai`.
    @Test("arquivar e aprender é um recibo só, com o endereço normalizado")
    func theArchiveAndLearnPairIsOneCompositeReceipt() async throws {
        let store = await loja([DiaDoDono.abacus])
        let receipts = ActionReceipts()

        receipts.beginBatch()
        _ = receipts.intercept(.move(messageID: "abacus", to: .archived), on: store, stamp: "14:32")
        _ = receipts.intercept(
            .learnSender(address: " No-Reply@Abacus.AI ", neverPriority: true),
            on: store, stamp: "14:32"
        )
        let recibo = try #require(receipts.sealBatch(stamp: "14:32"))
        #expect(store.message("abacus")?.bucket == .archived)
        #expect(store.silencesSender("no-reply@abacus.ai"), "a regra não foi aprendida")

        guard case let .restoreBatch(_, remetentes) = recibo.undo else {
            Issue.record("o desfazer da leva não é um recibo composto")
            return
        }
        #expect(remetentes == ["no-reply@abacus.ai"], "o endereço entrou cru no recibo")

        StoreCommand.run(recibo.undo, on: store)
        #expect(store.message("abacus")?.bucket == .today, "a mensagem não voltou")
        #expect(!store.silencesSender("no-reply@abacus.ai"), "a regra sobreviveu ao desfazer")
    }

    /// Fora de uma leva nada muda: apagar continua produzindo o recibo de
    /// sempre, e arquivar continua passando direto para o runner.
    @Test("fora da leva, o intercept de sempre não mudou")
    func outsideABatchNothingChanged() async throws {
        let store = await loja([DiaDoDono.jack, DiaDoDono.carol])
        let receipts = ActionReceipts()
        #expect(!receipts.intercept(
            .move(messageID: "carol", to: .archived), on: store, stamp: "14:32"
        ), "arquivar sozinho virou recibo")
        #expect(receipts.intercept(
            .move(messageID: "jack", to: .trash), on: store, stamp: "14:32"
        ))
        #expect(receipts.current?.messageID == "jack")
    }
}
