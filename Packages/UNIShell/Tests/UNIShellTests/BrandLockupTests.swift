import Testing
import CoreGraphics
import UNIDesign
@testable import UNIShell

@Suite("Marca na barra de título")
@MainActor
struct BrandLockupTests {

    @Test("a barra usa só o lobo, na escala do recolhe")
    func titlebarMarkIsAToolbarItem() {
        #expect(BrandLockup.markAssetName(isDark: false) == "uni-mark-light")
        #expect(BrandLockup.markAssetName(isDark: true) == "uni-mark-dark")
        #expect(BrandLockup.titlebarSize == 22)
        #expect(BrandLockup.titlebarSize < WindowChrome.sidebarControlSize)
        #expect(BrandLockup.titlebarSize <= TrafficLightLayout.contentCenterFromTop)
    }
}
