import Testing
@testable import UNICore

@Suite("Cores das caixas")
struct AccountTintTests {

    @Test("o catálogo tem as oito originais e espaço para muitas caixas")
    func catalogueKeepsOriginalsAndExpands() {
        #expect(AccountTint.count >= 20)
        #expect(AccountTint.catalogue.prefix(8).map(\.name) == [
            "Azul", "Violeta", "Verde", "Turquesa",
            "Magenta", "Laranja", "Vermelho", "Grafite",
        ])
        #expect(AccountTint.catalogue[0].lightHex == "#3F6AA1")
        #expect(AccountTint.catalogue[0].darkHex == "#8CBAF7")
    }

    @Test("cada cor tem nome e hex distintos")
    func namesAndHexesAreUnique() {
        let names = AccountTint.catalogue.map(\.name)
        let lights = AccountTint.catalogue.map(\.lightHex)
        let darks = AccountTint.catalogue.map(\.darkHex)
        #expect(Set(names).count == names.count)
        #expect(Set(lights).count == lights.count)
        #expect(Set(darks).count == darks.count)
        for tint in AccountTint.catalogue {
            #expect(tint.lightHex.hasPrefix("#"))
            #expect(tint.darkHex.hasPrefix("#"))
            #expect(tint.lightHex.count == 7)
            #expect(tint.darkHex.count == 7)
            #expect(tint.lightHex != tint.darkHex)
        }
    }

    @Test("o ciclo automático dá a volta em vez de acabar")
    func pairCycles() {
        let first = AccountTint.pair(forIndex: 0)
        #expect(first.light == AccountTint.catalogue[0].lightHex)
        let wrapped = AccountTint.pair(forIndex: AccountTint.count)
        #expect(wrapped.light == first.light)
        let negative = AccountTint.pair(forIndex: -1)
        #expect(negative.light == AccountTint.catalogue.last?.lightHex)
    }
}
