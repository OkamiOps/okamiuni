import Testing
import SwiftUI
import UNIDesign
import UNICore
@testable import UNIShell

@Suite("SidebarRail")
struct SidebarRailTests {

    @Test("a trilha tem a largura do design")
    func railWidth() {
        #expect(SidebarRail.width == 62)
    }

    @Test("as abreviações das quatro pastas estão na ordem certa", arguments: [
        (TriageBucket.today, "hoje"),
        (TriageBucket.later, "dep"),
        (TriageBucket.all, "tudo"),
        (TriageBucket.archived, "arq"),
    ])
    func bucketAbbreviations(bucket: TriageBucket, expected: String) {
        let abbr = SidebarRail.abbreviation(for: bucket)
        #expect(
            abbr == expected,
            "abreviação para \(bucket) deve ser '\(expected)', obteve '\(abbr)'"
        )
    }

    @Test("a marca de conta são as 3 primeiras letras do host")
    func accountMarkIsHostPrefix() {
        let account = Account(
            id: "zoho",
            address: "user@zoho.com",
            displayName: "Test User",
            provider: .imap,
            tintLightHex: "#000000",
            tintDarkHex: "#FFFFFF"
        )
        let mark = account.host.prefix(3).uppercased()
        #expect(mark == "ZOH", "as 3 primeiras letras de 'zoho' em maiúsculas são 'ZOH'")
    }

    @Test("marcar com gmail como exemplo")
    func accountMarkGmail() {
        let account = Account(
            id: "gma",
            address: "user@gmail.com",
            displayName: "Gmail User",
            provider: .gmail,
            tintLightHex: "#FF0000",
            tintDarkHex: "#FF6666"
        )
        let mark = account.host.prefix(3).uppercased()
        #expect(mark == "GMA", "as 3 primeiras letras de 'gma' em maiúsculas são 'GMA'")
    }
}
