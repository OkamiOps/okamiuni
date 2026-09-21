import Darwin
import Foundation
import UNICore
import UNISync

/// A headless, separately signed acceptance probe for the embedded XPC
/// service. It starts an empty loopback MCP server and performs only ACP's
/// initialize and session/new handshake; no prompt, mail, or tool call exists.
@main
struct ACPExternalRuntimeProbe {
    private static let serviceName = "com.okamiops.okamiuni.acp-release-probe.AgentRuntimeService"
    private static let expectedAgentName = "ACP fixture (home=real-user)"

    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            finish(success: false, reason: "missing-fixture")
            exit(EXIT_FAILURE)
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard fixtureURL.isFileURL, (fixtureURL.path as NSString).isAbsolutePath else {
            finish(success: false, reason: "invalid-fixture")
            exit(EXIT_FAILURE)
        }

        let server = LocalMCPServer(tools: []) { _, _ in .object([:]) }
        do {
            let endpoint = try await server.start()

            let configuration = AgentConnectionConfiguration(
                enabled: true,
                executablePath: fixtureURL.path
            )
            let runtime = ACPExternalRuntime(serviceName: serviceName, timeout: 20)
            let agentName = try await runtime.checkConnection(
                configuration: configuration,
                mcpURL: endpoint.url,
                bearerToken: endpoint.bearerToken
            )
            guard agentName == expectedAgentName else {
                await server.stop()
                finish(success: false, reason: "helper-home-is-not-user-home")
                exit(EXIT_FAILURE)
            }
            await server.stop()
            finish(success: true, reason: "")
            exit(EXIT_SUCCESS)
        } catch let error as ACPExternalRuntimeError {
            await server.stop()
            // The proof deliberately does not emit the returned error: it can
            // contain a runtime path or provider-originated operational data.
            finish(success: false, reason: "handshake-\(errorCode(error))")
            exit(EXIT_FAILURE)
        } catch {
            await server.stop()
            finish(success: false, reason: "handshake-unexpected")
            exit(EXIT_FAILURE)
        }
    }

    private static func finish(success: Bool, reason: String) {
        let output = success
            ? "ACP_EXTERNAL_RUNTIME_PROBE_OK signed-xpc=true sandboxed-client=true child-home=real-user handshake=check-only\n"
            : "ACP_EXTERNAL_RUNTIME_PROBE_FAILED \(reason)\n"
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    private static func errorCode(_ error: ACPExternalRuntimeError) -> String {
        switch error {
        case .unavailable: "unavailable"
        case .timedOut: "timed-out"
        case .invalidResponse: "invalid-response"
        case .invalidRequest: "invalid-request"
        case .cancelled: "cancelled"
        case .agentFailed: "agent-failed"
        case .agent: "agent-failed"
        }
    }
}
