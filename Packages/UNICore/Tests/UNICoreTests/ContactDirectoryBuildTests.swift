import Testing
import Foundation
@testable import UNICore

/// A montagem do catálogo **real** de contatos, a partir de quem recebeu
/// mensagens da pessoa — sem transformar todo remetente que chegou na caixa
/// em contato. `DatabaseContactDirectory`, no `UNISync`, só busca as
/// mensagens; quem filtra Enviadas, soma, deduplica e ordena é
/// `ContactDirectory.build`, e é isso que esta suíte prova.
@Suite("O catálogo real, montado das mensagens")
struct ContactDirectoryBuildTests {
    private func message(
        id: String, from: Contact, to: [Contact] = [], cc: [Contact] = [],
        bucket: TriageBucket = .today, at receivedAt: Date
    ) -> Message {
        Message(
            id: id, accountID: "conta-a", from: from, receivedAt: receivedAt,
            subject: "Assunto \(id)", snippet: "", body: [],
            tags: [], bucket: bucket, isRead: true,
            summary: nil, detectedEvent: nil, to: to, cc: cc
        )
    }

    private let t1 = Date(timeIntervalSince1970: 1_000)
    private let t2 = Date(timeIntervalSince1970: 2_000)
    private let t3 = Date(timeIntervalSince1970: 3_000)

    @Test("Remetente recebido não vira contato sem uma mensagem enviada para ele")
    func remetenteRecebidoNaoViraContato() {
        let messages = [
            message(
                id: "m1",
                from: Contact(name: "Kickstagogo", address: "team@kickstago.com"),
                to: [Contact(name: "Eu", address: "eu@x.com")],
                at: t1
            ),
        ]
        #expect(ContactDirectory.build(fromMessages: messages).isEmpty)
    }

    @Test("Destinatários e cópias de Enviadas entram; a própria conta não entra")
    func colheDestinatariosDeEnviadas() {
        let messages = [
            message(
                id: "m1",
                from: Contact(name: "Eu", address: "eu@x.com"),
                to: [
                    Contact(name: "Bruno", address: "bruno@x.com"),
                    Contact(name: "Eu", address: "EU@X.COM"),
                ],
                cc: [Contact(name: "Cláudia", address: "claudia@x.com")],
                bucket: .sent, at: t1
            ),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(Set(pool.map(\.address)) == ["bruno@x.com", "claudia@x.com"])
    }

    @Test("Mesmo endereço em mensagens diferentes é um contato só, com a frequência somada")
    func dedupPorEndereco() {
        let messages = [
            message(id: "m1", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Marina Duarte", address: "marina@x.com")], bucket: .sent, at: t1),
            message(id: "m2", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Marina Duarte", address: "marina@x.com")], bucket: .sent, at: t2),
            message(id: "m3", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Marina Duarte", address: "marina@x.com")], bucket: .sent, at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.count == 1)
        #expect(pool.first?.frequency == 3)
    }

    @Test("A dedup ignora caixa: MARINA@X.COM e marina@x.com são o mesmo contato")
    func dedupIgnoraCaixa() {
        let messages = [
            message(id: "m1", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Marina", address: "MARINA@X.COM")], bucket: .sent, at: t1),
            message(id: "m2", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Marina Duarte", address: "marina@x.com")], bucket: .sent, at: t2),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.count == 1)
        #expect(pool.first?.frequency == 2)
    }

    @Test("Mais frequente vem primeiro")
    func ordenaPorFrequencia() {
        let messages = [
            message(id: "m1", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Raro", address: "raro@x.com")], bucket: .sent, at: t1),
            message(id: "m2", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Frequente", address: "frequente@x.com")], bucket: .sent, at: t1),
            message(id: "m3", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Frequente", address: "frequente@x.com")], bucket: .sent, at: t2),
            message(id: "m4", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Frequente", address: "frequente@x.com")], bucket: .sent, at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.map(\.address) == ["frequente@x.com", "raro@x.com"])
    }

    @Test("Empate na frequência desfaz por quem apareceu mais recentemente")
    func empateDesfazPorRecencia() {
        let messages = [
            message(id: "m1", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Antigo", address: "antigo@x.com")], bucket: .sent, at: t1),
            message(id: "m2", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Recente", address: "recente@x.com")], bucket: .sent, at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.map(\.address) == ["recente@x.com", "antigo@x.com"])
    }

    @Test("Sem nome nenhuma vez, o nome fica vazio — sem inventar um a partir do endereço")
    func semNomeFicaVazio() {
        let messages = [
            message(id: "m1", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "", address: "sem.nome@x.com")], bucket: .sent, at: t1),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.first?.name == "")
    }

    @Test("O primeiro nome não vazio que aparece é o que fica")
    func primeiroNomeNaoVazioVence() {
        let messages = [
            message(id: "m1", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "", address: "x@x.com")], bucket: .sent, at: t1),
            message(id: "m2", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Nome Real", address: "x@x.com")], bucket: .sent, at: t2),
            message(id: "m3", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Outro Nome", address: "x@x.com")], bucket: .sent, at: t3),
        ]
        let pool = ContactDirectory.build(fromMessages: messages)
        #expect(pool.first?.name == "Nome Real")
    }

    @Test("Endereço vazio não vira contato")
    func enderecoVazioIgnorado() {
        let messages = [
            message(id: "m1", from: Contact(name: "Eu", address: "eu@x.com"),
                    to: [Contact(name: "Ninguém", address: "")], bucket: .sent, at: t1),
        ]
        #expect(ContactDirectory.build(fromMessages: messages).isEmpty)
    }

    @Test("Lista de mensagens vazia devolve catálogo vazio")
    func semMensagens() {
        #expect(ContactDirectory.build(fromMessages: []).isEmpty)
    }
}
