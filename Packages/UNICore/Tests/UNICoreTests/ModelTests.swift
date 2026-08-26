import Testing
import Foundation
@testable import UNICore

@Suite("Modelos")
struct ModelTests {

    @Test("iniciais saem do nome, não do email")
    func initialsFromName() {
        #expect(Contact(name: "Marina Duarte", address: "marina@x.com").initials == "MD")
        #expect(Contact(name: "Equipe Produto", address: "p@x.com").initials == "EP")
        #expect(Contact(name: "Ricardo", address: "r@x.com").initials == "R")
    }

    @Test("sem nome, as iniciais vêm do endereço")
    func initialsFromAddress() {
        #expect(Contact(name: "", address: "contato@meusite.com").initials == "C")
    }

    @Test("nomes com mais de duas palavras usam a primeira e a última")
    func initialsThreeWords() {
        #expect(Contact(name: "Ana Beatriz Silva", address: "a@x.com").initials == "AS")
    }

    @Test("as pastas de triagem batem com o protótipo")
    func triageBuckets() {
        #expect(TriageBucket.allCases.map(\.rawValue) == ["hoje", "depois", "todos", "arquivar"])
        #expect(TriageBucket.today.label == "Hoje")
        #expect(TriageBucket.later.label == "Depois")
        #expect(TriageBucket.all.label == "Tudo")
        #expect(TriageBucket.archived.label == "Arquivado")
    }

    @Test("a caixa Tudo aceita qualquer mensagem; as outras filtram")
    func bucketMatching() {
        let m = Message.preview(bucket: .today)
        #expect(TriageBucket.all.contains(m))
        #expect(TriageBucket.today.contains(m))
        #expect(TriageBucket.archived.contains(m) == false)
    }
}
