import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// Quando o formulário de conta oferece o login por navegador do Zoho.
///
/// Regra pura, afirmada sem `View` nenhuma — a mesma disciplina de
/// `AddAccountForm.route`: o que decide a tela é testável sozinho, e por isso
/// mexer no desenho não apaga a prova.
@Suite("O botão Entrar com Zoho")
struct ZohoSignInButtonTests {
    @Test("Caixa pessoal do Zoho: o endereço basta")
    func enderecoDoZoho() {
        #expect(ZohoSignInButton.applies(address: "marina@zoho.com", host: ""))
        #expect(ZohoSignInButton.applies(address: "marina@zohomail.com", host: "imap.zoho.com"))
    }

    @Test("Domínio próprio no Zoho: quem diz é o servidor, não o endereço")
    func dominioProprio() {
        // É o caso que mais ganha com o login sem senha de app, e é
        // justamente o que o endereço sozinho nunca revelaria.
        #expect(ZohoSignInButton.applies(address: "marina@aempresa.com", host: "imap.zoho.com"))
        #expect(ZohoSignInButton.applies(address: "marina@aempresa.com", host: "imappro.zoho.eu"))
    }

    @Test("Fora do Zoho, o botão não existe")
    func foraDoZoho() {
        #expect(ZohoSignInButton.applies(address: "marina@gmail.com", host: "") == false)
        #expect(ZohoSignInButton.applies(
            address: "marina@aempresa.com", host: "imap.aempresa.com"
        ) == false)
        #expect(ZohoSignInButton.applies(address: "", host: "") == false)
    }
}
