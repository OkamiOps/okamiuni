import Testing
@testable import UNIDesign

@Suite("FontRegistry")
struct FontRegistryTests {

    @Test("a lista de famílias exigidas cobre todas as usadas pelos temas")
    func requiredCoversThemes() {
        var used = Set<String>()
        for theme in Theme.all {
            for family in [theme.serif, theme.sans, theme.mono] {
                if let name = family.name { used.insert(name) }
            }
        }
        let declared = Set(FontRegistry.required)
        #expect(used.subtracting(declared).isEmpty,
                "temas usam famílias não declaradas: \(used.subtracting(declared))")
    }

    @Test("FontFamily cai no system font quando a face não está instalada")
    func fallsBackWhenMissing() {
        let ghost = FontFamily(name: "Fonte Que Nao Existe", design: .serif)
        // Não deve travar nem devolver uma fonte inválida.
        _ = ghost.font(size: 14)
        #expect(FontRegistry.isAvailable("Fonte Que Nao Existe") == false)
    }
}
