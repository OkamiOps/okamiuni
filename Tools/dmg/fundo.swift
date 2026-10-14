// Desenha o fundo da janela do instalador (.dmg) do OkamiUNI.
//
// Uso: swift Tools/dmg/fundo.swift <pasta-de-saída>
// Gera fundo.png (1x) e fundo@2x.png; o dmgbuild junta os dois num TIFF
// para telas Retina. As posições dos ícones moram em Tools/dmg/settings.py e
// têm de bater com as constantes abaixo.

import AppKit
import CoreText

let largura: CGFloat = 640
let altura: CGFloat = 400
/// Centro dos ícones, medido do topo — o mesmo de `icon_locations`.
let centroApp = CGPoint(x: 170, y: 214)
let centroAplicativos = CGPoint(x: 470, y: 214)

let raiz = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fontes = raiz.appendingPathComponent("App/Resources/Fonts")
for nome in ["Inter.ttf", "SpaceGrotesk.ttf"] {
    CTFontManagerRegisterFontsForURL(fontes.appendingPathComponent(nome) as CFURL, .process, nil)
}
let lockup = NSImage(contentsOf: raiz.appendingPathComponent(
    "App/Resources/Assets.xcassets/uni-lockup-light.imageset/uni-lockup-light.png"))!

// Paleta Tinta (Themes+Generated.swift).
func cor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
let papel = cor(255, 255, 255)
let tinta2 = cor(69, 81, 94)
let tinta4 = cor(104, 112, 125)
let acento = cor(20, 86, 240)
let acentoSuave = cor(238, 244, 255)

func fonte(_ nome: String, _ tamanho: CGFloat, peso: NSFont.Weight) -> NSFont {
    let descritor = NSFontDescriptor(fontAttributes: [.family: nome])
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: peso]])
    return NSFont(descriptor: descritor, size: tamanho) ?? .systemFont(ofSize: tamanho, weight: peso)
}

/// Converte uma coordenada medida do topo (como no Finder) para o sistema do
/// AppKit, que cresce para cima.
func y(_ doTopo: CGFloat) -> CGFloat { altura - doTopo }

func textoCentralizado(_ texto: String, fonte: NSFont, cor: NSColor, topo: CGFloat) {
    let atributos: [NSAttributedString.Key: Any] = [.font: fonte, .foregroundColor: cor]
    let tamanho = (texto as NSString).size(withAttributes: atributos)
    (texto as NSString).draw(
        at: CGPoint(x: (largura - tamanho.width) / 2, y: y(topo) - tamanho.height),
        withAttributes: atributos)
}

func desenhar() {
    papel.setFill()
    CGRect(x: 0, y: 0, width: largura, height: altura).fill()

    // Marca no topo.
    // A imagem do logotipo traz fiapos de borda: desenha só o miolo.
    let miolo = CGRect(x: 0, y: 0, width: lockup.size.width, height: lockup.size.height)
        .insetBy(dx: lockup.size.width * 0.03, dy: lockup.size.height * 0.12)
    let alturaLockup: CGFloat = 32
    let larguraLockup = alturaLockup * miolo.width / miolo.height
    lockup.draw(in: CGRect(x: (largura - larguraLockup) / 2, y: y(30) - alturaLockup,
                           width: larguraLockup, height: alturaLockup),
                from: miolo, operation: .sourceOver, fraction: 1)

    // Seta entre os dois ícones, no acento.
    let inicio = centroApp.x + 84
    let fim = centroAplicativos.x - 84
    let meio = y(centroApp.y)
    let trilho = NSBezierPath(roundedRect: CGRect(x: inicio - 6, y: meio - 18,
                                                  width: fim - inicio + 12, height: 36),
                              xRadius: 18, yRadius: 18)
    acentoSuave.setFill()
    trilho.fill()
    let haste = NSBezierPath()
    haste.move(to: CGPoint(x: inicio + 14, y: meio))
    haste.line(to: CGPoint(x: fim - 16, y: meio))
    haste.lineWidth = 3
    haste.lineCapStyle = .round
    acento.setStroke()
    haste.stroke()
    let ponta = NSBezierPath()
    ponta.move(to: CGPoint(x: fim - 26, y: meio + 9))
    ponta.line(to: CGPoint(x: fim - 15, y: meio))
    ponta.line(to: CGPoint(x: fim - 26, y: meio - 9))
    ponta.lineWidth = 3
    ponta.lineCapStyle = .round
    ponta.lineJoinStyle = .round
    ponta.stroke()

    // A instrução fica no alto: o rodapé da janela pode ser coberto pelas
    // barras de caminho e de status, quando a pessoa as deixa ligadas no Finder.
    textoCentralizado("Arraste o OkamiUNI para a pasta Aplicativos",
                      fonte: fonte("Inter", 14, peso: .semibold), cor: tinta2, topo: 82)
    textoCentralizado("Drag OkamiUNI to the Applications folder",
                      fonte: fonte("Inter", 12, peso: .regular), cor: tinta4, topo: 104)
}

func salvar(escala: CGFloat, em url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(largura * escala), pixelsHigh: Int(altura * escala),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: largura, height: altura)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    desenhar()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let saida = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try! FileManager.default.createDirectory(at: saida, withIntermediateDirectories: true)
salvar(escala: 1, em: saida.appendingPathComponent("fundo.png"))
salvar(escala: 2, em: saida.appendingPathComponent("fundo@2x.png"))
print("fundo.png e fundo@2x.png em \(saida.path)")
