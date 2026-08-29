import WebKit

/// A sessão que **todas** as `WebView` do leitor dividem enquanto o app roda.
///
/// ## O defeito que ela conserta
///
/// "Sair da mensagem e voltar custa os mesmos trinta segundos, toda vez." E
/// custava mesmo: o bloco de HTML é jogado fora e refeito a cada abertura
/// (`.id(message.id)` no leitor), e cada `WebView` nova nascia com um
/// `WKWebsiteDataStore.nonPersistent()` **próprio**. As onze imagens da
/// mensagem desciam de novo, inteiras, todas as vezes.
///
/// **Dividir o armazenamento não bastou, e isso foi medido.** Com a sessão
/// comum e duas `WebView`, o servidor de teste continuou contando dois
/// pedidos: numa sessão de memória o WebKit não guarda o recurso baixado. E
/// mesmo que guardasse, a imagem de campanha vem quase sempre com `no-store` —
/// cache nenhum a guardaria.
///
/// O que resolve é não desmanchar o que já está pronto: o **acervo** abaixo
/// guarda a página inteira, `WebView` e tudo, e a segunda visita a recebe de
/// volta desenhada, na altura em que ficou. Zero pedido, zero espera.
///
/// ## Por que continua não persistente
///
/// A tentação é `.default()` — cache em disco, e a mensagem abre rápido até
/// depois de reiniciar. **Não.** Um email não tem sessão, e o que fica no disco
/// de uma página de remetente não é só imagem: é cookie, armazenamento local e
/// o rastro de quem abriu o quê e quando. Em memória, por sessão, é a troca
/// honesta: a espera some dentro do uso do dia, e nada do remetente sobrevive
/// ao app fechar.
///
/// ## O que continua valendo
///
/// A configuração é **nova a cada `WebView`**, e só o armazenamento e o
/// processo é que são comuns: a lista de bloqueio de imagens remotas mora no
/// `userContentController` da configuração, e compartilhá-lo faria o "Carregar"
/// de uma mensagem valer para a seguinte — exatamente a permissão global que
/// esta tela não tem.
@MainActor
enum ReaderWebSession {
    /// O armazenamento comum. Uma instância por processo, viva enquanto o app
    /// roda, morta com ele.
    static let dados = WKWebsiteDataStore.nonPersistent()

    /// O processo de rede comum. Sem ele, cada `WebView` fala com um processo
    /// próprio e o cache do vizinho é de outro mundo.
    static let processos = WKProcessPool()

    /// Uma configuração nova, com a sessão comum dentro dela.
    static func configuracao() -> WKWebViewConfiguration {
        let configuracao = WKWebViewConfiguration()
        // Nenhum script da mensagem roda. Ver `ReaderHTMLBody`.
        configuracao.defaultWebpagePreferences.allowsContentJavaScript = false
        configuracao.websiteDataStore = dados
        configuracao.processPool = processos
        return configuracao
    }

    // MARK: - O acervo

    /// Uma página já desenhada, guardada inteira: a `WebView`, o documento que
    /// está nela e a altura que a régua mediu.
    struct Pagina {
        let assinatura: String
        let view: WebViewQueNaoRouba
        let altura: CGFloat
    }

    /// Quantas mensagens ficam prontas para voltar.
    ///
    /// Seis, e não "todas": cada `WebView` é cara (processo de conteúdo,
    /// bitmaps), e guardar tudo o que foi aberto numa manhã trocaria a espera
    /// por memória sem teto. Seis cobre o vaivém real — a mensagem que se abre,
    /// se fecha e se reabre — e é onde a lista mais antiga começa a cair.
    static let limite = 6

    /// As páginas ociosas, da mais antiga para a mais nova.
    private static var acervo: [Pagina] = []

    /// Tira a página do acervo — quem a pega passa a ser dono dela.
    ///
    /// Sair do acervo, e não ficar nele: a mesma mensagem pode estar aberta no
    /// leitor e na janela 05 ao mesmo tempo, e uma `NSView` não vive em dois
    /// lugares. A segunda abertura simplesmente carrega do zero.
    static func retira(_ assinatura: String) -> Pagina? {
        guard let onde = acervo.firstIndex(where: { $0.assinatura == assinatura })
        else { return nil }
        return acervo.remove(at: onde)
    }

    static func guarda(_ pagina: Pagina) {
        acervo.removeAll { $0.assinatura == pagina.assinatura }
        acervo.append(pagina)
        if acervo.count > limite { acervo.removeFirst(acervo.count - limite) }
    }

    /// Só para o teste: um acervo limpo entre um caso e outro.
    static func esvazia() { acervo.removeAll() }

    static var guardadas: Int { acervo.count }
}
