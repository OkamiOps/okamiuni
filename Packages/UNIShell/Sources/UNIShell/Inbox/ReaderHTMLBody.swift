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
/// - **Lembrar depois de fechar.** O armazenamento não é persistente: cookie,
///   cache e armazenamento local morrem com o app. Um email não tem sessão. O
///   que ele guarda **enquanto o app roda** é comum a todas as mensagens desde
///   a M3-22 — ver `ReaderWebSession` para por que isso não é o contrário
///   disto.
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
    /// O conteúdo já pintou?
    ///
    /// **É o mesmo sinal que a medição da M3-18/M3-20 já observa**, e não um
    /// segundo relógio: `didFinish` espera o evento `load` do documento (com as
    /// imagens dentro dele — medido na M3-18), e a régua responde logo depois.
    /// Quando a primeira altura de verdade chega, a mensagem está desenhada.
    /// Enquanto não chega, quem espera na tela é o `ReaderHTMLSection`.
    ///
    /// **Volta a falso a cada carga nova** (M3-22). Sem isso, apertar
    /// "Carregar" numa mensagem já pintada trocava o documento por um em branco
    /// com o sinal ainda ligado — e era esse o caminho dos "trinta segundos de
    /// nada" que o dono relatou.
    @Binding var pintou: Bool

    func makeCoordinator() -> Coordenador { Coordenador(self) }

    func makeNSView(context: Context) -> WKWebView {
        // **A mensagem que já foi lida volta pronta.** Ver `ReaderWebSession`:
        // o leitor destrói este bloco a cada troca de mensagem, e sem o acervo
        // voltar para a mensagem de ontem é baixar tudo de novo.
        let webView = ReaderWebSession.retira(context.coordinator.assinatura(de: self))
            .map { guardada -> WebViewQueNaoRouba in
                context.coordinator.reaproveita(guardada)
                return guardada.view
            }
            ?? WebViewQueNaoRouba(frame: .zero, configuration: ReaderWebSession.configuracao())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        // A largura do painel muda quando alguém arrasta a divisória — e a
        // escala de "caber sem cortar" é calculada contra ela. Sem este aviso, o
        // email encolhido para um painel estreito continuaria encolhido depois
        // de o painel dobrar de largura.
        // Os dois fracos, e não por zelo: a `WebView` guarda a closure, e uma
        // closure que a guardasse de volta seria um ciclo — uma `WebView` por
        // mensagem aberta, vivas até o app fechar.
        webView.aoMudarLargura = { [weak webView, weak coordenador = context.coordinator] (largura: CGFloat) in
            guard let webView else { return }
            coordenador?.ajusta(webView, largura: largura)
        }
        context.coordinator.carrega(em: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pai = self
        context.coordinator.carrega(em: webView)
    }

    /// Fechar a mensagem **guarda** a página em vez de queimá-la.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordenador) {
        MainActor.assumeIsolated { coordinator.guarda(nsView) }
    }

    // MARK: - O delegado

    @MainActor
    final class Coordenador: NSObject, WKNavigationDelegate {
        var pai: ReaderHTMLBody
        /// O que já foi carregado, para não recarregar a cada redesenho —
        /// recarregar reinicia a rolagem e pisca a tela a cada tecla digitada
        /// noutro painel.
        private var ultimoCarregado: String?

        /// Entradas que realmente mudam o documento. SwiftUI chama
        /// `updateNSView` por mudanças vizinhas (seleção, painel de IA,
        /// rascunho); uma newsletter grande não deve repetir sanitização,
        /// regex e montagem de CSS em cada uma delas.
        private struct EntradaDocumento: Equatable {
            let html: String
            let permiteRemotas: Bool
            let fundo: String
            let tinta: String
            let link: String
            let fonte: String
        }

        private var documentoEmCache: (
            entrada: EntradaDocumento,
            assinatura: String,
            html: String
        )?

        /// O teto da espera, armado quando a navegação termina. Ver
        /// `ReaderHTMLSection.tetoDaEspera`.
        private var tetoDaRegua: Task<Void, Never>?

        deinit { tetoDaRegua?.cancel() }

        /// A última altura que a régua devolveu. É ela que volta com a página
        /// guardada: sem isso a `WebView` reaproveitada entraria com um ponto de
        /// altura e a mensagem piscaria antes de reabrir no tamanho certo.
        private var ultimaAltura: CGFloat = 1
        /// A página desta `WebView` chegou a pintar de verdade — a régua
        /// respondeu. Só uma dessas vale a pena guardar.
        private var pintouDeVerdade = false

        /// Qual carga está na tela.
        ///
        /// **A medição é assíncrona, e a carga seguinte não a espera.** O
        /// `didFinish` agenda uma segunda passada 120ms depois; se nesse meio
        /// tempo a pessoa aperta "Carregar", a resposta da régua **do documento
        /// velho** chegava e anunciava "pintou" por cima do documento novo, que
        /// ainda estava descendo — a espera sumia da tela e voltava a coluna em
        /// branco. Medido: era o que restava dos "trinta segundos de nada"
        /// depois do primeiro conserto. Cada resposta agora diz de que carga
        /// ela é, e a atrasada é descartada.
        private var geracao = 0

        init(_ pai: ReaderHTMLBody) {
            self.pai = pai
            super.init()
        }

        /// O que identifica o documento que está (ou vai) na tela: o HTML já
        /// montado com o tema, mais a permissão de imagem remota. Duas
        /// mensagens diferentes, dois documentos; a mesma mensagem com as
        /// imagens liberadas, outro documento — e é por isso que apertar
        /// "Carregar" recarrega.
        func documento(de corpo: ReaderHTMLBody) -> (assinatura: String, html: String) {
            let entrada = EntradaDocumento(
                html: corpo.html,
                permiteRemotas: corpo.permiteRemotas,
                fundo: corpo.fundo,
                tinta: corpo.tinta,
                link: corpo.link,
                fonte: corpo.fonte
            )
            if let cache = documentoEmCache, cache.entrada == entrada {
                return (cache.assinatura, cache.html)
            }
            let documento = ReaderHTMLPolicy.documento(
                html: corpo.html, fundo: corpo.fundo, tinta: corpo.tinta,
                link: corpo.link, fonte: corpo.fonte,
                bloqueiaRemotas: !corpo.permiteRemotas
            )
            let assinatura = "\(corpo.permiteRemotas)\n\(documento)"
            documentoEmCache = (entrada, assinatura, documento)
            return (assinatura, documento)
        }

        func assinatura(de corpo: ReaderHTMLBody) -> String {
            documento(de: corpo).assinatura
        }

        /// A página que voltou do acervo já está desenhada: nada é recarregado,
        /// e o leitor a mostra na altura em que ela ficou.
        func reaproveita(_ guardada: ReaderWebSession.Pagina) {
            ultimoCarregado = guardada.assinatura
            ultimaAltura = guardada.altura
            pintouDeVerdade = true
            // Fora do desenho em curso: isto roda dentro do `makeNSView`, e
            // escrever num `@State` no meio da montagem da `View` é
            // justamente o que o SwiftUI proíbe.
            let altura = guardada.altura
            Task { @MainActor [self] in
                pai.altura = altura
                pai.pintou = true
            }
        }

        /// Devolve a página ao acervo quando o bloco sai da tela.
        func guarda(_ webView: WKWebView) {
            tetoDaRegua?.cancel()
            tetoDaRegua = nil
            guard pintouDeVerdade, let assinatura = ultimoCarregado,
                  let view = webView as? WebViewQueNaoRouba
            else { return }
            view.aoMudarLargura = nil
            view.navigationDelegate = nil
            ReaderWebSession.guarda(
                .init(assinatura: assinatura, view: view, altura: ultimaAltura)
            )
        }

        func carrega(em webView: WKWebView) {
            let (assinatura, documento) = documento(de: pai)
            guard assinatura != ultimoCarregado else { return }
            ultimoCarregado = assinatura
            geracao += 1
            pintouDeVerdade = false

            // **Carga nova é espera nova — e é o defeito da M3-21.** O sinal só
            // nascia falso; ninguém o devolvia para falso quando um segundo
            // documento começava a carregar. O caminho que leva os trinta
            // segundos é justamente esse: a pessoa aperta "Carregar", as onze
            // imagens remotas saem pela rede, e a `WebView` fica em branco com
            // `pintou` ainda ligado da carga anterior — vinte segundos de nada,
            // sem a espera que a M3-21 desenhou.
            tetoDaRegua?.cancel()
            tetoDaRegua = nil

            let permite = pai.permiteRemotas
            Task { @MainActor [self] in
                // Fora do desenho em curso, pelo mesmo motivo do
                // `reaproveita`: `carrega` é chamado de dentro do `makeNSView`
                // e do `updateNSView`.
                if pai.pintou { pai.pintou = false }
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
            ajusta(webView, largura: webView.bounds.width)
            // Segunda passada: a primeira acontece antes de as imagens
            // embutidas terem layout, e uma newsletter cresce meia tela quando
            // elas entram. Sem ela, o fim da mensagem fica cortado.
            let geracao = self.geracao
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                ajusta(webView, largura: webView.bounds.width, geracao: geracao)
            }
            armaOTeto()
        }

        /// Navegação que falhou também acaba a espera: sem isto, um documento
        /// que nunca carrega deixaria a roda girando para sempre.
        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            armaOTeto()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            armaOTeto()
        }

        /// O teto começa **aqui**, e não na abertura: enquanto a rede trabalha
        /// a espera é verdade, e desligá-la no meio devolveria a coluna vazia
        /// que o dono viu. Ver `ReaderHTMLSection.tetoDaEspera`.
        private func armaOTeto() {
            guard tetoDaRegua == nil else { return }
            tetoDaRegua = Task { @MainActor [weak self] in
                try? await Task.sleep(for: ReaderHTMLSection.tetoDaEspera)
                guard let self, !Task.isCancelled else { return }
                if !self.pai.pintou { self.pai.pintou = true }
            }
        }

        /// A escala que faz o email caber, e a altura que ele passa a ter.
        ///
        /// Duas perguntas ao documento, nesta ordem, porque a segunda depende da
        /// primeira: quanto o conteúdo mede de largura (com a régua em 1, senão
        /// a resposta já vem contaminada pela escala anterior) e quanto ele mede
        /// de altura **depois** de a escala entrar.
        ///
        /// `evaluateJavaScript` do **app** continua funcionando com
        /// `allowsContentJavaScript = false`: aquele interruptor é sobre o
        /// script que a mensagem traz, não sobre o que nós perguntamos. Medido
        /// na prática, não deduzido do cabeçalho.
        func ajusta(_ webView: WKWebView, largura: CGFloat) {
            ajusta(webView, largura: largura, geracao: geracao)
        }

        private func ajusta(_ webView: WKWebView, largura: CGFloat, geracao: Int) {
            guard largura > 0 else { return }
            webView.pageZoom = 1
            // `body.scrollWidth`, e **não** `documentElement.scrollWidth`: com
            // `overflow: hidden` no `html`, o segundo devolve a largura do
            // painel mesmo quando o conteúdo é maior — ou seja, mede a régua em
            // vez do que está sendo medido. Foi assim que o corte passou
            // despercebido.
            webView.evaluateJavaScript("document.body.scrollWidth") { [weak self] valor, _ in
                guard let self, self.geracao == geracao else { return }
                let conteudo = (valor as? CGFloat) ?? 0
                let escala = ReaderHTMLPolicy.escala(painel: largura, conteudo: conteudo)
                webView.pageZoom = escala
                self.mede(webView, escala: escala, geracao: geracao)
            }
        }

        private func mede(_ webView: WKWebView, escala: CGFloat, geracao: Int) {
            webView.evaluateJavaScript(
                ReaderHTMLPolicy.medidaDaAltura
            ) { [weak self] valor, _ in
                guard let self, self.geracao == geracao,
                      let numero = valor as? CGFloat, numero > 0 else { return }
                // A régua respondeu com um número de verdade: o documento está
                // desenhado. É aqui, e não no `didFinish`, porque entre os dois
                // a `WebView` ainda mede um ponto de altura — anunciar "pintou"
                // lá deixaria um fio no lugar da mensagem.
                if !self.pai.pintou { self.pai.pintou = true }
                self.pintouDeVerdade = true
                let altura = ReaderHTMLPolicy.altura(documento: numero, escala: escala)
                self.ultimaAltura = altura
                guard abs(altura - self.pai.altura) > 1 else { return }
                self.pai.altura = altura
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
final class WebViewQueNaoRouba: WKWebView {
    /// Avisado quando a largura muda de verdade — a divisória de painéis
    /// arrastada, a janela redimensionada. A altura muda o tempo todo (é a
    /// própria medição que a muda), e reagir a ela seria um laço.
    var aoMudarLargura: ((CGFloat) -> Void)?
    private var ultimaLargura: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - ultimaLargura) > 0.5 else { return }
        ultimaLargura = newSize.width
        aoMudarLargura?(newSize.width)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    override var acceptsFirstResponder: Bool { false }
}
