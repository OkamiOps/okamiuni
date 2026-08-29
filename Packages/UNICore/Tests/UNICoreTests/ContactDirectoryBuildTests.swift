import Testing
import Foundation
@testable import UNICore

/// A montagem do catálogo **real** de contatos, a partir das mensagens que o
/// banco (ou as fixtures) já têm — sem tabela nova, sem porta nenhuma
/// envolvida. `DatabaseContactDirectory`, no `UNISync`, só busca as
/// mensagens; quem soma, deduplica e ordena é `ContactDirectory.build`, e é
/// isso que esta suíte prova.
@Suite("O catálogo real, montado das mensagens")
struct ContactDirectoryBuildTests {
    private func message(
        id: String, from: Contact, to: [Contact] = [], cc: [Contact] = [],
        at receivedAt: Date
    ) -> Message {
        Message(
            id: id, accountID: "conta-a", from: from, receivedAt: receivedAt,
            subject: "Assunto \(id)", snippet: "", body: [],
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil, to: to, cc: cc
        )
    }

    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)
    private let t3 = Date(timeIntervalSince1970: 3_000)

    @Test("Remetente, destinatário e cópia contam todos")
    func colheDosTresLugares() {
        let messages = [
            message(
                id: "m1",
                from: Contact(name: "Marina Duarte", address: "marina@x.com"),
                to: [Contact(name: "Bruno", address: "bruno@x.com")],
                cc: [Contact(name: "Cláudia", address: "claudia@x.com")],
                at: t1
            ),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(Set(pool.map(\.address)) == ["marina@x.com", "bruno@x.com", "claudia@x.com"])
    }

    @Test("Mesmo endereço em mensagens diferentes é um contato só, com a frequência somada")
    func dedupPorEndereco() {
        let messages = [
            message(id: "m1", from: Contact(name: "Marina Duarte", address: "marina@x.com"), at: t1),
            message(id: "m2", from: Contact(name: "Marina Duarte", address: "marina@x.com"), at: t2),
            message(id: "m3", from: Contact(name: "Marina Duarte", address: "marina@x.com"), at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.count == 1)
        #expect(pool.first?.frequency == 3)
    }

    @Test("A dedup ignora caixa: MARINA@X.COM e marina@x.com são o mesmo contato")
    func dedupIgnoraCaixa() {
        let messages = [
            message(id: "m1", from: Contact(name: "Marina", address: "MARINA@X.COM"), at: t1),
            message(id: "m2", from: Contact(name: "Marina Duarte", address: "marina@x.com"), at: t2),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.count == 1)
        #expect(pool.first?.frequency == 2)
    }

    @Test("Mais frequente vem primeiro")
    func ordenaPorFrequencia() {
        let messages = [
            message(id: "m1", from: Contact(name: "Raro", address: "raro@x.com"), at: t1),
            message(id: "m2", from: Contact(name: "Frequente", address: "frequente@x.com"), at: t1),
            message(id: "m3", from: Contact(name: "Frequente", address: "frequente@x.com"), at: t2),
            message(id: "m4", from: Contact(name: "Frequente", address: "frequente@x.com"), at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.map(\.address) == ["frequente@x.com", "raro@x.com"])
    }

    @Test("Empate na frequência desfaz por quem apareceu mais recentemente")
    func empateDesfazPorRecencia() {
        let messages = [
            message(id: "m1", from: Contact(name: "Antigo", address: "antigo@x.com"), at: t1),
            message(id: "m2", from: Contact(name: "Recente", address: "recente@x.com"), at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.map(\.address) == ["recente@x.com", "antigo@x.com"])
    }

    @Test("Sem nome nenhuma vez, o nome fica vazio — sem inventar um a partir do endereço")
    func semNomeFicaVazio() {
        let messages = [
            message(id: "m1", from: Contact(name: "", address: "sem.nome@x.com"), at: t1),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.first?.name == "")
    }

    @Test("O primeiro nome não vazio que aparece é o que fica")
    func primeiroNomeNaoVazioVence() {
        let messages = [
            message(id: "m1", from: Contact(name: "", address: "x@x.com"), at: t1),
            message(id: "m2", from: Contact(name: "Nome Real", address: "x@x.com"), at: t2),
            message(id: "m3", from: Contact(name: "Outro Nome", address: "x@x.com"), at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.first?.name == "Nome Real")
    }

    @Test("Endereço vazio não vira contato")
    func enderecoVazioIgnorado() {
        let messages = [
            message(id: "m1", from: Contact(name: "Ninguém", address: ""), at: t1),
        ]
        #expect(ContactDirectory.build(fromMessages: messages).isEmpty)
    }

    @Test("Lista de mensagens vazia devolve catálogo vazio")
    func semMensagens() {
        #expect(ContactDirectory.build(fromMessages: []).isEmpty)
    }
}
