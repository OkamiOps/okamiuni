import Foundation
import Testing
@testable import UNISync

/// O que vai para o log unificado do sistema, e com que marca.
///
/// **Por que este teste lê o código-fonte.** A marca de privacidade de uma
/// interpolação de `Logger` é resolvida em tempo de compilação e não deixa
/// nenhum rastro que o processo possa observar: não há gancho de runtime, e
/// ler o log do sistema de dentro do teste exigiria permissão que um teste não
/// tem (e traria o log da máquina inteira junto). A única observação possível é
/// a do texto, e ela é honesta sobre isso.
///
/// O que se protege não é estilo: `AccountDirector.accountID(for:)` só passa o
/// endereço para caixa baixa e troca o que não for alfanumérico/`@.-_` por `-`,
/// então para `marina@clientepremium.com` o id **é** o endereço. Marcado
/// `.public`, ele era gravado em claro no log unificado — visível em `log show`
/// e recolhido em qualquer sysdiagnose.
@Suite("O que vai para o log do sistema")
struct LogPrivacyTests {
    /// A raiz do pacote, a partir deste arquivo:
    /// `…/UNISync/Tests/UNISyncTests/LogPrivacyTests.swift` → `…/UNISync`.
    private static var fontes: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UNISyncTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // UNISync
            .appendingPathComponent("Sources/UNISync")
    }

    private static func arquivosSwift() throws -> [(nome: String, texto: String)] {
        let raiz = fontes
        guard let percurso = FileManager.default.enumerator(
            at: raiz, includingPropertiesForKeys: nil
        ) else { return [] }
        var saida: [(String, String)] = []
        for caso in percurso {
            guard let url = caso as? URL, url.pathExtension == "swift" else { continue }
            saida.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return saida
    }

    @Test("Nenhum identificador de pessoa vai ao log marcado como público")
    func identificadorNuncaEhPublico() throws {
        // As três formas que carregam dado da pessoa: o id da conta (que é o
        // endereço), o endereço em si, e o nome de pasta vindo do servidor.
        //
        // MUTAÇÃO QUE ISTO PEGA: devolver `privacy: .public` a qualquer uma das
        // interpolações de `accountID`, `account.address` ou `pasta`.
        let proibidas = [
            "\\(accountID, privacy: .public)",
            "\\(account.address, privacy: .public)",
            "\\(address, privacy: .public)",
            "\\(pasta, privacy: .public)",
        ]
        let arquivos = try Self.arquivosSwift()
        // O teste tem de estar lendo alguma coisa: uma raiz errada faria ele
        // passar sobre zero arquivo, que é a forma mais silenciosa de mentir.
        #expect(arquivos.count > 10, "achei \(arquivos.count) arquivos — a raiz está errada")
        #expect(arquivos.contains { $0.nome == "AccountDirector.swift" })

        for (nome, texto) in arquivos {
            for proibida in proibidas {
                #expect(!texto.contains(proibida), "\(nome) marca \(proibida) como pública")
            }
        }
    }

    @Test("Nenhum segredo é interpolado em log nenhum")
    func segredoNuncaVaiAoLog() throws {
        // O contrapeso, e o que de fato importa mais: a marca de privacidade
        // atrasa o dado, mas segredo não pode entrar na linha nem marcado.
        for (nome, texto) in try Self.arquivosSwift() {
            for linha in texto.split(separator: "\n") where linha.contains("log.") {
                for proibido in ["accessToken", "refreshToken", "senha", "password", "\\(segredo"] {
                    #expect(
                        !linha.contains("\\(" + proibido) && !linha.contains(proibido + ","),
                        "\(nome) interpola \(proibido) num log: \(linha)"
                    )
                }
            }
        }
    }
}
