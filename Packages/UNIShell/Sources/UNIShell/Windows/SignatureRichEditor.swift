import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UniformTypeIdentifiers
import WebKit

/// As três superfícies de uma assinatura: escrever, editar o documento e
/// conferir exatamente o que sai no e-mail. Não são três cópias do dado: o
/// HTML, o texto alternativo e as imagens CID continuam no mesmo
/// `EmailSignature`.
enum SignatureEditorMode: String, CaseIterable, Identifiable {
    case visual
    case html
    case preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .visual: "Visual"
        case .html: "HTML"
        case .preview: "Prévia"
        }
    }
}

/// O editor visual e o campo HTML são duas superfícies para a mesma
/// assinatura, mas não dois codecs perfeitamente reversíveis. Em particular,
/// tabelas de uma assinatura importada não devem ser achatadas para texto só
/// porque a pessoa abriu a prévia. Esta marca explícita guarda qual superfície
/// foi alterada por último e é consultada no save.
enum SignatureEditorSource: String, Equatable {
    case visual
    case html
}

/// Editor rico usado exclusivamente em Configurações ▸ Assinaturas.
///
/// O composer e este editor compartilham o mesmo TextKit e a mesma barra de
/// formatação. Assim, negrito, links, cor, listas e tabelas não viram uma
/// imitação de interface: são os mesmos comandos que já produzem HTML na
/// mensagem. Imagens incorporadas vêm de arquivo ou de `data:image`, são
/// gravadas no banco em bytes locais e entram no HTML por `cid:`. Uma imagem
/// HTTPS já presente numa assinatura importada pode continuar externa — a UI
/// deixa essa dependência explícita antes de salvar.
struct SignatureRichEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    @Binding var visualText: AttributedString
    @Binding var selection: AttributedTextSelection
    @Binding var html: String
    @Binding var resources: [InlineSignatureResource]
    @Binding var mode: SignatureEditorMode
    @Binding var canonicalSource: SignatureEditorSource

    let visualDidChange: () -> Void
    let htmlDidChange: () -> Void
    let resourcesDidChange: () -> Void
    let report: (_ text: String, _ isError: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Modo do editor", selection: $mode) {
                    ForEach(SignatureEditorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 248)
                .accessibilityLabel("Modo do editor de assinatura")

                Spacer(minLength: 8)

                Menu {
                    Button("Arquivo HTML…") { chooseHTML() }
                } label: {
                    Label("Importar", systemImage: "arrow.down.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Importar um arquivo HTML para editar a assinatura")

                Button {
                    chooseImage()
                } label: {
                    Label("Adicionar imagem", systemImage: "photo.badge.plus")
                }
                .buttonStyle(SignatureQuietButtonStyle())
                .help("Escolher uma imagem local para incorporar na assinatura")
                .accessibilityHint("A imagem será enviada dentro do e-mail, sem URL remota")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.surface2.color)

            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))

            Group {
                switch mode {
                case .visual:
                    visualEditor
                case .html:
                    htmlEditor
                case .preview:
                    preview
                }
            }
            // Uma assinatura real costuma ter uma tabela de 600px. O editor
            // fica dentro do ScrollView da janela de Configurações, então
            // deixar esse espaço não corta nem achata a prévia.
            .frame(minHeight: 560, maxHeight: 760, alignment: .topLeading)

            imageShelf
        }
        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
        }
        // Os painéis da barra (cor, link, tabela) são overlays. Sem essa
        // pilha explícita, o editor ou a prateleira de imagem os cortaria.
        .zIndex(3)
    }

    private var visualEditor: some View {
        VStack(spacing: 0) {
            ComposerToolbar(
                reading: ComposerEditor.reading(of: visualText, selection: selection),
                density: .window,
                perform: { command in
                    ComposerEditor.perform(
                        command,
                        on: &visualText,
                        selection: &selection,
                        theme: theme
                    )
                    markVisualEdited()
                }
            )
            .zIndex(2)

            if canonicalSource == .html,
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Esta assinatura veio de HTML. Ao editar aqui, o modo Visual passa a ser a fonte salva e pode simplificar tabelas e layout.")
                }
                .font(theme.sans.font(size: 10.5))
                .foregroundStyle(theme.ink3.color)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.accentSoft.color.opacity(0.48))
            }

            ZStack(alignment: .topLeading) {
                ComposerTextView(
                    text: $visualText,
                    selection: $selection,
                    theme: theme,
                    insets: CGSize(width: 16, height: 14),
                    scrolls: true,
                    onEdit: markVisualEdited
                )

                if visualText.characters.isEmpty {
                    Text("Nome, cargo, telefone e links…")
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(theme.ink4.color)
                        .padding(.horizontal, 16)
                        .padding(.top, 15)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var htmlEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorSectionLabel("CÓDIGO HTML")
            TextEditor(text: Binding(
                get: { html },
                set: { value in
                    html = value
                    markHTMLEdited()
                }
            ))
            .font(theme.mono.font(size: 11.5))
            .foregroundStyle(theme.ink.color)
            .scrollContentBackground(.hidden)
            .padding(12)
            .frame(height: 172)
            .accessibilityLabel("Código HTML da assinatura")

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10, weight: .semibold))
                Text("Scripts e conteúdo perigoso são removidos. Imagens HTTPS podem continuar externas; use CID para levá-las dentro do e-mail.")
            }
            .font(theme.sans.font(size: 10.5))
            .foregroundStyle(theme.ink3.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2.color)

            livePreview(label: "RESULTADO AO VIVO")
        }
    }

    private var preview: some View {
        livePreview(label: "PRÉVIA DA ASSINATURA")
    }

    private func editorSectionLabel(_ title: String) -> some View {
        Text(title)
            .capsLabel()
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2.color)
    }

    private func livePreview(label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            editorSectionLabel(label)

            if let document = previewDocument {
                SignaturePreviewWebView(html: document)
                    .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 520)
                    .accessibilityLabel("Prévia segura da assinatura")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "signature")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(theme.ink4.color)
                    Text("Sua assinatura aparecerá aqui")
                        .font(theme.sans.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.ink2.color)
                    Text("Cole o HTML acima ou escreva no modo Visual.")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                }
                .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 520)
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10, weight: .semibold))
                Text("Scripts, navegação e recursos perigosos continuam bloqueados. Imagens HTTPS da assinatura podem ser exibidas como externas.")
            }
            .font(theme.sans.font(size: 10.5))
            .foregroundStyle(theme.ink3.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2.color)
        }
    }

    private func markVisualEdited() {
        canonicalSource = .visual
        visualDidChange()
    }

    private func markHTMLEdited() {
        canonicalSource = .html
        htmlDidChange()
    }

    private var imageShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("IMAGENS INCORPORADAS")
                    .capsLabel()
                Spacer(minLength: 0)
                Text(resources.isEmpty ? "Nenhuma" : "\(resources.count)/\(EmailSignature.maximumInlineResourceCount)")
                    .font(theme.mono.font(size: 9.5))
                    .foregroundStyle(theme.ink4.color)
            }

            if resources.isEmpty {
                Text("Adicione PNG, JPEG, GIF ou WebP. A imagem viaja dentro do e-mail, sem depender de hospedagem externa.")
                    .font(theme.sans.font(size: 10.8))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(resources) { resource in
                            SignatureImageChip(resource: resource) {
                                remove(resource)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(theme.surface2.color)
    }

    private var previewDocument: String? {
        let candidate: String?
        let previewResources: [InlineSignatureResource]
        switch canonicalSource {
        case .visual:
            candidate = SignatureRichDocument.html(from: visualText, resources: resources, theme: theme)
            previewResources = resources
        case .html:
            // Este é também o caminho de Cmd+V no TextEditor. Normalizar só
            // no botão "Importar" deixaria `data:image` invisível justamente
            // no fluxo mais comum. A normalização é local e não altera o
            // rascunho enquanto a pessoa digita; o mesmo resultado é usado no
            // save, quando os bytes passam a integrar a assinatura.
            let imported = SignatureHTMLImporter.normalize(
                source: html,
                existingResources: resources
            )
            candidate = imported.html
            previewResources = imported.inlineResources
        }
        return SignatureRichDocument.previewDocument(
            html: candidate,
            resources: previewResources,
            theme: theme
        )
    }

    private func chooseImage() {
        guard resources.count < EmailSignature.maximumInlineResourceCount else {
            report("A assinatura pode conter no máximo \(EmailSignature.maximumInlineResourceCount) imagens.", true)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Escolher imagem da assinatura"
        panel.message = "A imagem será incorporada no e-mail. PNG, JPEG, GIF ou WebP; até 2 MB por arquivo."
        panel.prompt = "Adicionar imagem"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif]
            + [UTType(filenameExtension: "webp")].compactMap { $0 }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            addImage(at: url)
        }
    }

    private func chooseHTML() {
        let panel = NSOpenPanel()
        panel.title = "Importar assinatura HTML"
        panel.message = "O HTML será revisado antes de salvar. Scripts são removidos; imagens HTTPS podem permanecer externas."
        panel.prompt = "Importar HTML"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html, .plainText]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importHTML(at: url)
        }
    }

    private func importHTML(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            // O arquivo bruto pode ser maior que o HTML persistido porque uma
            // logo `data:image` vira um recurso CID separado na importação.
            // O limite final de 128 KB continua valendo para o fragmento já
            // normalizado dentro de `EmailSignature`.
            let maximumImportByteCount = 8 * 1_024 * 1_024
            guard data.count <= maximumImportByteCount else {
                report("O arquivo HTML passa do limite de 8 MB para importação.", true)
                return
            }
            guard let source = String(data: data, encoding: .utf8) else {
                report("O arquivo HTML precisa estar em UTF-8.", true)
                return
            }
            importHTML(source)
        } catch {
            report("Não foi possível ler o arquivo HTML: \(error.localizedDescription)", true)
        }
    }

    /// Arquivos HTML podem trazer imagens `data:` copiadas de outro cliente.
    /// O importador as converte para CID antes da prévia e preserva tabelas/
    /// estilos inline. A edição digitada continua livre — normalizá-la a cada
    /// tecla destruiria um atributo parcialmente escrito.
    private func importHTML(_ source: String) {
        let result = SignatureHTMLImporter.normalize(
            source: source,
            existingResources: resources
        )
        let resourcesChanged = result.inlineResources != resources
        html = result.html
        resources = result.inlineResources
        mode = .html
        markHTMLEdited()
        if resourcesChanged {
            resourcesDidChange()
        }

        var details = ["HTML importado e renderizado abaixo do código."]
        if !result.externalImageURLs.isEmpty {
            details.append("\(result.externalImageURLs.count) imagem(ns) HTTPS continuam externas.")
        }
        details.append(contentsOf: result.warnings)
        report(details.joined(separator: " "), false)
    }

    private func addImage(at url: URL) {
        guard let mimeType = SignatureRichDocument.mimeType(for: url) else {
            report("Escolha uma imagem PNG, JPEG, GIF ou WebP.", true)
            return
        }

        do {
            let resource = try InlineSignatureResource(mimeType: mimeType, data: Data(contentsOf: url))
            resources.append(resource)
            let base = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SignatureRichDocument.plainHTML(String(visualText.characters))
                : html
            html = SignatureRichDocument.ensuringImages(base, resources: resources)
            resourcesDidChange()
            report("Imagem incorporada. Ela não será carregada de um servidor externo.", false)
        } catch {
            report(error.localizedDescription, true)
        }
    }

    private func remove(_ resource: InlineSignatureResource) {
        resources.removeAll { $0.contentID == resource.contentID }
        html = SignatureRichDocument.removingImage(
            resource.contentID,
            from: html
        )
        resourcesDidChange()
        report("Imagem removida da assinatura.", false)
    }
}

private struct SignatureImageChip: View {
    @Environment(\.theme) private var theme
    let resource: InlineSignatureResource
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image = NSImage(data: resource.data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink3.color)
                }
            }
            .frame(width: 30, height: 30)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 1) {
                Text(resource.mimeType.replacingOccurrences(of: "image/", with: "").uppercased())
                    .font(theme.mono.font(size: 9.5))
                    .foregroundStyle(theme.ink2.color)
                Text(ByteCountFormatter.string(fromByteCount: Int64(resource.data.count), countStyle: .file))
                    .font(theme.mono.font(size: 8.5))
                    .foregroundStyle(theme.ink4.color)
            }

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink3.color)
            .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Remover imagem \(resource.mimeType)")
        }
        .padding(6)
        .background(theme.paper.color, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SignatureQuietButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.sans.font(size: 11, weight: .medium))
            .foregroundStyle(theme.ink2.color)
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(
                configuration.isPressed ? theme.surface3.color : theme.surface.color,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
    }
}

/// Transformações pequenas e testáveis entre o editor, o HTML armazenado e a
/// prévia local. Mantê-las fora da `View` impede que uma troca de aba vire uma
/// requisição de rede ou faça a assinatura perder a alternativa texto.
enum SignatureRichDocument {
    @MainActor
    static func html(
        from text: AttributedString,
        resources: [InlineSignatureResource],
        theme: Theme
    ) -> String? {
        let plain = String(text.characters)
        // A exportação HTML do AppKit normalmente põe CSS num `<style>` no
        // cabeçalho. `EmailSignature` remove `<style>` por segurança, portanto
        // usar esse resultado aqui faria B/I/cor sumirem depois de salvar. O
        // codec abaixo escreve somente atributos inline derivados do modelo
        // tipado do composer; nenhum CSS arbitrário da pessoa entra por este
        // caminho.
        guard ComposerOutgoing.hasFormatting(text) || !resources.isEmpty else { return nil }
        var document = inlineHTML(from: text)
        if document.isEmpty, (!plain.isEmpty || !resources.isEmpty) {
            document = plain.isEmpty ? "<div></div>" : "<div>\(escaped(plain).replacingOccurrences(of: "\n", with: "<br>"))</div>"
        }
        return ensuringImages(document, resources: resources)
    }

    static func ensuringImages(
        _ document: String,
        resources: [InlineSignatureResource]
    ) -> String {
        var result = document
        for resource in resources where !result.localizedCaseInsensitiveContains("cid:\(resource.contentID)") {
            let tag = "<p><img src=\"cid:\(resource.contentID)\" alt=\"\"></p>"
            if let bodyEnd = result.range(of: "</body>", options: .caseInsensitive) {
                result.insert(contentsOf: tag, at: bodyEnd.lowerBound)
            } else {
                result += tag
            }
        }
        return result
    }

    static func plainHTML(_ text: String) -> String {
        "<div>\(escaped(text).replacingOccurrences(of: "\n", with: "<br>"))</div>"
    }

    static func removingImage(_ contentID: String, from html: String) -> String {
        // O sanitizador também descarta qualquer tag órfã na gravação. Esta
        // passada deixa a prévia coerente imediatamente, antes do próximo Save.
        html
            .replacingOccurrences(of: "<img src=\"cid:\(contentID)\" alt=\"\">", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "<img src='cid:\(contentID)' alt=''>", with: "", options: [.caseInsensitive])
    }

    static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }

    static func previewDocument(
        html: String?,
        resources: [InlineSignatureResource],
        theme: Theme,
        bodyPadding: CGFloat = 16
    ) -> String? {
        guard var safeHTML = EmailSignature.sanitizedHTML(html, inlineResources: resources) else {
            return nil
        }
        // Na prévia, CIDs viram data URLs produzidas a partir dos bytes que a
        // pessoa acabou de escolher. Imagens HTTPS que passaram pelo
        // sanitizador permanecem externas para que uma assinatura importada
        // possa ser conferida como ela realmente será enviada. Não há base URL
        // e a CSP não autoriza scripts, conexões, fontes ou frames.
        for resource in resources {
            let dataURL = "data:\(resource.mimeType);base64,\(resource.data.base64EncodedString())"
            safeHTML = safeHTML.replacingOccurrences(of: "cid:\(resource.contentID)", with: dataURL)
        }

        // Uma assinatura que já declarou cores é um pequeno documento autoral,
        // não uma extensão do canvas da janela. Reusar a mesma decisão do
        // leitor evita texto escuro sobre a superfície escura do app e mantém
        // os estilos inline da assinatura como foram enviados.
        let usesPaper = ReaderHTMLPolicy.paleta(para: safeHTML) == .papel
        let background = usesPaper ? "#ffffff" : css(theme.surface)
        let foreground = usesPaper ? "#1a1a1a" : css(theme.ink)
        let link = usesPaper ? "#1155cc" : css(theme.accent)
        let colorScheme = usesPaper ? "light" : "light dark"
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
        <style>:root{color-scheme:\(colorScheme)}html,body{margin:0;padding:0;background:\(background);color:\(foreground);font:13px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.45}body{padding:\(max(0, bodyPadding))px}a{color:\(link)}img{max-width:100%;height:auto}</style>
        </head><body>\(safeHTML)</body></html>
        """
    }

    static func visualText(from signature: EmailSignature, theme: Theme) -> AttributedString {
        var text = AttributedString(signature.plainText)
        ComposerEditor.decorate(&text, theme: theme)
        return text
    }

    /// Codec próprio do texto rico para uma assinatura. A entrada é o modelo
    /// `RichBody`, não um fragmento HTML arbitrário, então a lista de estilos
    /// é deliberadamente pequena e toda escapada. É o que preserva formatação
    /// depois de o sanitizador retirar a folha `<style>` do AppKit.
    private static func inlineHTML(from text: AttributedString) -> String {
        let paragraphs = RichBody.paragraphs(of: text)
        var index = 0
        var result = ""

        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            guard let seed = RichBody.tableCell(of: text, at: paragraph) else {
                result += paragraphHTML(paragraph, in: text)
                index += 1
                continue
            }

            // As células que o composer cria são parágrafos consecutivos. A
            // tabela no HTML precisa respeitar `row` e `column`, não apenas a
            // ordem, porque a pessoa pode preencher a grade em qualquer ordem.
            let expected = max(1, seed.rows * seed.columns)
            var cells: [(cell: BodyTableCell, paragraph: Range<AttributedString.Index>)] = []
            while index < paragraphs.count, cells.count < expected {
                let candidate = paragraphs[index]
                guard let cell = RichBody.tableCell(of: text, at: candidate), cell.table == seed.table else {
                    break
                }
                cells.append((cell, candidate))
                index += 1
            }

            result += "<table style=\"border-collapse:collapse\"><tbody>"
            for row in 0..<max(1, seed.rows) {
                result += "<tr>"
                for column in 0..<max(1, seed.columns) {
                    let content = cells.first { $0.cell.row == row && $0.cell.column == column }
                        .map { paragraphContent($0.paragraph, in: text) } ?? "<br>"
                    result += "<td style=\"padding:3px 7px;vertical-align:top\">\(content)</td>"
                }
                result += "</tr>"
            }
            result += "</tbody></table>"
        }
        return result
    }

    private static func paragraphHTML(
        _ paragraph: Range<AttributedString.Index>, in text: AttributedString
    ) -> String {
        let alignmentCSS: String
        switch RichBody.alignment(of: text, at: paragraph) {
        case .left: alignmentCSS = "left"
        case .center: alignmentCSS = "center"
        case .right: alignmentCSS = "right"
        case .justified: alignmentCSS = "justify"
        }
        let content = paragraphContent(paragraph, in: text)
        return "<div style=\"text-align:\(alignmentCSS)\">\(content.isEmpty ? "<br>" : content)</div>"
    }

    private static func paragraphContent(
        _ paragraph: Range<AttributedString.Index>, in text: AttributedString
    ) -> String {
        text[paragraph].runs.map { run in
            let style = RichBody.style(of: run.attributes)
            let value = escaped(String(text[run.range].characters))
            var css: [String] = []
            if let family = safeFontFamily(style.family) {
                css.append("font-family:'\(family)'")
            }
            css.append("font-size:\(Int(style.size.rounded()))px")
            if style.bold { css.append("font-weight:700") }
            if style.italic { css.append("font-style:italic") }
            var decorations: [String] = []
            if style.underline { decorations.append("underline") }
            if style.strike { decorations.append("line-through") }
            if !decorations.isEmpty { css.append("text-decoration:\(decorations.joined(separator: " "))") }
            if let color = safeColor(style.colorHex) { css.append("color:\(color)") }
            if let highlight = safeColor(style.highlightHex) { css.append("background-color:\(highlight)") }

            let span = "<span style=\"\(css.joined(separator: ";"))\">\(value)</span>"
            guard let link = run.attributes.link else { return span }
            return "<a href=\"\(escaped(link.absoluteString))\">\(span)</a>"
        }.joined()
    }

    private static func safeFontFamily(_ family: String) -> String? {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({
                  CharacterSet.letters.union(.decimalDigits).union(.whitespaces).union(CharacterSet(charactersIn: "-_")).contains($0)
              })
        else { return nil }
        return trimmed.replacingOccurrences(of: "'", with: "")
    }

    private static func safeColor(_ value: String) -> String? {
        guard value.count == 7, value.first == "#",
              value.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return nil }
        return value.uppercased()
    }

    private static func css(_ token: TokenColor) -> String {
        let channel = { (value: Double) in Int((max(0, min(1, value)) * 255).rounded()) }
        return "rgba(\(channel(token.red)), \(channel(token.green)), \(channel(token.blue)), \(token.opacity))"
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// WebKit só é usado para renderizar HTML que acabou de passar pela
/// sanitização. A política de navegação ainda cancela qualquer destino que não
/// seja o próprio documento, como defesa em profundidade contra uma regressão
/// do sanitizador.
struct SignaturePreviewWebView: NSViewRepresentable {
    let html: String
    /// Quando a superfície que hospeda a prévia precisa crescer junto com a
    /// assinatura (como o composer), ela passa um binding. Configurações deixa
    /// isso `nil` e mantém a altura fixa da própria tela.
    private let measuredHeight: Binding<CGFloat>?

    init(html: String, measuredHeight: Binding<CGFloat>? = nil) {
        self.html = html
        self.measuredHeight = measuredHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(measuredHeight: measuredHeight) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WebViewQueNaoRouba(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.aoMudarLargura = { [weak webView, weak coordinator = context.coordinator] _ in
            guard let webView else { return }
            coordinator?.measure(webView)
        }
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.measuredHeight = measuredHeight
        context.coordinator.load(html, in: webView)
        context.coordinator.measure(webView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        (nsView as? WebViewQueNaoRouba)?.aoMudarLargura = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedHTML: String?
        private var generation = 0
        var measuredHeight: Binding<CGFloat>?

        init(measuredHeight: Binding<CGFloat>?) {
            self.measuredHeight = measuredHeight
        }

        func load(_ html: String, in webView: WKWebView) {
            guard loadedHTML != html else { return }
            loadedHTML = html
            generation += 1
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Imagens CID e HTTPS podem entrar no layout imediatamente após o
            // `load` terminar. Uma segunda medição mantém a altura correta sem
            // dar à WebView uma rolagem própria.
            let expectedGeneration = generation
            Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, let webView, self.generation == expectedGeneration else { return }
                self.measure(webView)
            }
        }

        /// Mede no documento já sanitizado. `allowsContentJavaScript` bloqueia
        /// JavaScript da assinatura; esta consulta é executada pelo app e é a
        /// mesma técnica usada pelo leitor HTML para acomodar conteúdo rico.
        func measure(_ webView: WKWebView) {
            guard measuredHeight != nil, webView.bounds.width > 0 else { return }
            let expectedGeneration = generation
            webView.evaluateJavaScript(
                "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
            ) { [weak self] value, _ in
                guard let self, self.generation == expectedGeneration else { return }
                let measured = (value as? NSNumber)?.doubleValue ?? Double((value as? CGFloat) ?? 0)
                guard measured > 0 else { return }
                let height = CGFloat(measured)
                guard abs((self.measuredHeight?.wrappedValue ?? 0) - height) > 0.5 else { return }
                self.measuredHeight?.wrappedValue = height
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            // Links nunca deixam a prévia. HTTPS é permitido exclusivamente
            // fora do frame principal para imagens externas autorizadas pela
            // CSP; JavaScript segue desativado na configuração da WebView.
            if navigationAction.targetFrame?.isMainFrame == false, scheme == "https" {
                decisionHandler(.allow)
            } else {
                decisionHandler((scheme == "about" || scheme == "data") ? .allow : .cancel)
            }
        }
    }
}
