import AppKit
import SwiftUI
import UNIDesign
import WebKit

/// O corpo da mensagem desenhado como HTML.
///
/// **A única `WebView` do app**, e a razão de ela existir: o email do provedor
/// — logotipo, tabela, botão — é HTML, e desenhá-lo como parágrafos de texto é
/// a diferença que o dono viu entre este leitor e o webmail. O texto continua
/// sendo o caminho de toda mensagem que não tem HTML; esta peça é a outra
/// metade, não a substituta.
///
/// ## O que ela não pode fazer
///
/// - **Executar.** `allowsContentJavaScript = false`: nenhum script da
///   mensagem roda. O que `MimeSanitize` já arrancou não volta por aqui.
/// - **Buscar.** A lista de regras barra todo `http`/`https` antes do primeiro
///   pixel. Carregar é uma escolha por mensagem, e ela não fica guardada.
/// - **Navegar.** Todo link sai para o navegador padrão — ver
///   `ReaderHTMLPolicy.decide(url:)`.
/// - **Lembrar.** `WKWebsiteDataStore.nonPersistent()`: cookie, cache e
///   armazenamento local morrem com a janela. Um email não tem sessão.
/// - **Roubar.** Ela não aceita foco, devolve a roda do mouse para o leitor e
///   não responde a atalho nenhum — os do app continuam sendo do app.
struct ReaderHTMLBody: NSViewRepresentable {
    /// O HTML **já sanitizado** por `MimeSanitize`. Esta peça não limpa nada:
    /// limpar em dois lugares é divergir em um deles.
    let html: String
    /// A pessoa pediu para carregar as imagens remotas desta mensagem?
    let permiteRemotas: Bool
    let fundo: String
    let tinta: String
    let link: String
    let fonte: String
    /// A altura medida do conteúdo. É ela que faz a `WebView` crescer dentro da
    /// rolagem do leitor em vez de rolar por dentro.
    @Binding var altura: CGFloat

    func makeCoordinator() -> Coordenador { Coordenador(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuracao = WKWebViewConfiguration()
        configuracao.defaultWebpagePreferences.allowsContentJavaScript = false
        // Sem persistência: um email não tem sessão, e um cookie de rastreio
        // que sobrevivesse à mensagem seria o pixel de rastreio com memória.
        configuracao.websiteDataStore = .nonPersistent()

        let webView = WebViewQueNaoRouba(frame: .zero, configuration: configuracao)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.carrega(em: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pai = self
        context.coordinator.carrega(em: webView)
    }

    // MARK: - O delegado

    @MainActor
    final class Coordenador: NSObject, WKNavigationDelegate {
        var pai: ReaderHTMLBody
        /// O que já foi carregado, para não recarregar a cada redesenho —
        /// recarregar reinicia a rolagem e pisca a tela a cada tecla digitada
        /// noutro painel.
        private var ultimoCarregado: String?

        init(_ pai: ReaderHTMLBody) {
            self.pai = pai
            super.init()
        }

        func carrega(em webView: WKWebView) {
            let documento = ReaderHTMLPolicy.documento(
                html: pai.html, fundo: pai.fundo, tinta: pai.tinta,
                link: pai.link, fonte: pai.fonte
            )
            let assinatura = "\(pai.permiteRemotas)\n\(documento)"
            guard assinatura != ultimoCarregado else { return }
            ultimoCarregado = assinatura

            let permite = pai.permiteRemotas
            Task { @MainActor in
                // **A regra entra antes do documento.** Compilar depois de
                // carregar deixaria a primeira leva de imagens sair pela rede —
                // e o pixel de rastreio só precisa de uma.
                webView.configuration.userContentController.removeAllContentRuleLists()
                if !permite, let regra = await Self.regraDeBloqueio() {
                    webView.configuration.userContentController.add(regra)
                }
                webView.loadHTMLString(documento, baseURL: nil)
            }
        }

        /// A lista compilada, uma vez por processo.
        ///
        /// Compilar custa milissegundos e acontece a cada mensagem aberta: sem
        /// guardar, abrir dez mensagens é compilar dez vezes a mesma regra.
        private static var compilada: WKContentRuleList?

        static func regraDeBloqueio() async -> WKContentRuleList? {
            if let compilada { return compilada }
            let lista = try? await WKContentRuleListStore.default()?
                .compileContentRuleList(
                    forIdentifier: ReaderHTMLPolicy.identificadorDaRegra,
                    encodedContentRuleList: ReaderHTMLPolicy.regraDeBloqueio
                )
            compilada = lista
            return lista
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            switch ReaderHTMLPolicy.decide(url: navigationAction.request.url) {
            case .permitir:
                decisionHandler(.allow)
            case .abrirNoNavegador(let url):
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            case .recusar:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            mede(webView)
            // Segunda medida: a primeira acontece antes de as imagens
            // embutidas terem layout, e uma newsletter cresce meia tela quando
            // elas entram. Sem ela, o fim da mensagem fica cortado.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                mede(webView)
            }
        }

        /// A altura do conteúdo, perguntada ao próprio documento.
        ///
        /// `evaluateJavaScript` do **app** continua funcionando com
        /// `allowsContentJavaScript = false`: aquele interruptor é sobre o
        /// script que a mensagem traz, não sobre o que nós perguntamos.
        private func mede(_ webView: WKWebView) {
            webView.evaluateJavaScript(
                "document.documentElement.scrollHeight"
            ) { [weak self] valor, _ in
                guard let self, let numero = valor as? CGFloat, numero > 0 else { return }
                guard abs(numero - self.pai.altura) > 1 else { return }
                self.pai.altura = numero
            }
        }
    }
}

/// A `WebView` que devolve o que não é dela.
///
/// Três recusas, e nenhuma é cosmética: a roda do mouse volta para o leitor
/// (senão a mensagem rola por dentro e a coluna não anda), o atalho volta para
/// o app (senão ⌘R deixa de responder quando o foco cai aqui), e o foco nunca
/// vem para cá (a `WebView` não tem nada para digitar).
private final class WebViewQueNaoRouba: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    override var acceptsFirstResponder: Bool { false }
}
