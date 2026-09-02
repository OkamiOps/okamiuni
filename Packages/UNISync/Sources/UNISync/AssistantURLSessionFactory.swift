import Foundation

/// `URLRequest.timeoutInterval` só cobre a espera entre pacotes. Um prompt
/// de 400 mil caracteres com resposta longa estoura o **recurso**, não o
/// pedido — e o dono já viu o Grok morrer assim. Os dois tempos são
/// gravados juntos, uma vez, na sessão que o roteador guarda.
enum AssistantURLSessionFactory {
    static func timed(basedOn session: URLSession, timeout: TimeInterval) -> URLSession {
        // `session.configuration` devolve uma cópia; mutá-la não afeta a
        // sessão de origem e preserva `protocolClasses`, que é o que
        // mantém os testes com StubURLProtocol valendo.
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }
}
