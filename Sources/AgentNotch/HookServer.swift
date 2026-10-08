import AgentNotchCore
import Foundation
import Network

/// Answers one HTTP request. Permission requests keep it until the person clicks; if Claude Code
/// gives up first (Esc, timeout), `onGone` fires so the card can be taken down.
final class Responder {
    private let connection: NWConnection
    private var finished = false
    var onGone: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(json: Data, status: Int = 200) {
        send(HTTPResponse.make(status: status, body: json))
    }

    func send(text: String, status: Int = 200) {
        send(HTTPResponse.make(status: status, contentType: "text/plain", body: Data(text.utf8)))
    }

    private func send(_ response: Data) {
        guard !finished else { return }
        finished = true
        connection.send(content: response, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    /// Watches a held connection: the client closing its side means nobody is waiting anymore.
    func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self, !self.finished else { return }
            if isComplete || error != nil {
                self.finished = true
                self.connection.cancel()
                self.onGone?()
            } else {
                self.watchForClose()
            }
        }
    }
}

/// HTTP endpoint for Claude Code's `http` hooks, bound to the loopback interface only.
/// Runs on the main queue: traffic is a handful of small requests per second at most.
final class HookServer {
    private let port: UInt16
    private var listener: NWListener?
    var onRequest: ((HTTPRequest, Responder) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let parameters = NWParameters.tcp
        // Bind to 127.0.0.1 itself, not the wildcard address: nothing off this Mac can reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.onFailure?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(on: connection, buffer: Data())
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func receive(on connection: NWConnection, buffer: Data, expectedTotal: Int? = nil) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            // Don't re-parse a large body on every read once its size is known.
            if let expectedTotal, buffer.count < expectedTotal, !isComplete, error == nil {
                self.receive(on: connection, buffer: buffer, expectedTotal: expectedTotal)
                return
            }

            switch HTTPParser.parse(buffer) {
            case .complete(let request):
                self.onRequest?(request, Responder(connection: connection))
            case .invalid(let reason):
                Responder(connection: connection).send(text: reason, status: 400)
            case .incomplete(let total):
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, expectedTotal: total)
                }
            }
        }
    }
}
