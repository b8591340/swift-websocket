import Foundation
import Combine

public enum WebSocketError: Swift.Error {
    case alreadyConnectedOrConnecting
    case notConnected
    case cannotParseMessage(String)
}

extension WebSocket {
    public enum State {
        /// The socket is initialized and ready to connect.
        case notConnected
        /// The WebSocket is in the process of connecting.
        case connecting
        /// The WebSocket is connected.
        case connected
        /// The WebSocket is disconnected after being connected.
        case disconnected
    }
}

public class WebSocket {
    public private(set) var state: State = .notConnected

    public let messages: AsyncThrowingStream<Data, Error>

    private let socketTask: URLSessionWebSocketTask
    private var socketTaskDelegate: SocketTaskDelegate?

    private let messagesContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var heartbeatTask: Task<Void, Error>?

    /// Intializes a new WebSocket.
    ///
    /// - Parameters:
    ///   - request: The URLRequest used when conneting the WebSocket.
    ///   - urlSession: The URLSession used when connecting the WebSocket.
    public init(request: URLRequest, urlSession: URLSession = URLSession.shared) {

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        self.messages = stream
        self.messagesContinuation = continuation

        self.socketTask = urlSession.webSocketTask(with: request)
    }

    public convenience init(url: URL, urlSession: URLSession = URLSession.shared) {
        self.init(request: URLRequest(url: url), urlSession: urlSession)
    }

    deinit {
        try? disconnect()
    }

    // MARK: - Connecting / Disconnecting

    /// Connects the WebSocket. You may only call this once per instance.
    ///
    /// After the WebSocket disconnects, it can no longer be connected. If you want to establish a new connection
    /// you must create a new WebSocket instance.
    ///
    /// - Throws WebSocketError.alreadyConnectedOrConnecting when the WebSocket state is not `.notConnected`.
    public func connect() async throws {
        guard state == .notConnected else {
            throw WebSocketError.alreadyConnectedOrConnecting
        }

        state = .connecting

        try await withCheckedThrowingContinuation { continuation in
            let delegate = SocketTaskDelegate { _ in
                self.state = .connected
                continuation.resume()
                self.receive()

            } onWebSocketTaskDidClose: { _, _ in
                self.handleDisconnect(withError: nil)

            } onWebSocketTaskDidCompleteWithError: { error in
                // Only propagate errors that occur during the process of connecting the socket.
                if let error, self.state == .connecting {
                    continuation.resume(throwing: error)
                }

                self.handleDisconnect(withError: error)
            }

            self.socketTaskDelegate = delegate
            socketTask.delegate = delegate

            socketTask.resume()
        }
    }
    
    /// Disconnects the WebSocket.
    ///
    /// After the WebSocket disconnects, it can no longer be connected. If you want to establish a new connection
    /// you must create a new WebSocket instance.
    func disconnect() throws {
        guard state == .connected else {
            throw WebSocketError.notConnected
        }

        messagesContinuation.finish()

        socketTask.cancel(with: .normalClosure, reason: nil)
        socketTaskDelegate = nil
    }

    // MARK: - Sending Data

    /// Sends the given encodable `value` through the WebSocket.
    ///
    /// - Parameters:
    ///   - value: The encodable value that is sent through the websocket.
    ///   - encoder: The encoder used to encode the value.
    ///
    /// - Throws WebSocketError.notConnected when the `send` method is called before the WebSocket is connected.
    public func send<Encoder>(
        _ value: any Encodable,
        encoder: Encoder
    ) async throws where Encoder: TopLevelEncoder, Encoder.Output == Data {
        let data = try encoder.encode(value)
        try await send(.data(data))
    }
    
    /// Sends the given `string` through the websocket.
    ///
    /// - Throws WebSocketError.notConnected when the `send` method is called before the WebSocket is connected.
    public func send(_ string: String) async throws {
        try await send(.string(string))
    }

    /// Sends the given `data` through the WebSocket.
    ///
    /// - Throws WebSocketError.notConnected when the `send` method is called before the WebSocket is connected.
    public func send(_ data: Data) async throws {
        try await send(.data(data))
    }

    // MARK: - Heartbeats

    /// Start sending a heartbeat at regular intervals.
    ///
    /// - Parameters:
    ///   - heartbeat: The heartbeat data to send.
    ///   - interval: The interval between heartbeats.
    public func startHeartbeats(sending heartbeat: Data, every interval: Duration) {
        heartbeatTask?.cancel()

        heartbeatTask = Task {
            if Task.isCancelled { return }

            try await send(heartbeat)

            try await Task.sleep(for: interval)

            startHeartbeats(sending: heartbeat, every: interval)
        }
    }

    /// Stop sending heartbeats.
    public func stopHeartbeats() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Private

    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard state == .connected else {
            throw WebSocketError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socketTask.send(message) { error in
                if let error {
                    continuation.resume(with: .failure(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func receive() {
        socketTask.receive { [weak self] result in
            switch result {
            case .success(.data(let data)):
                self?.messagesContinuation.yield(data)
                self?.receive()

            case .success(.string(let string)):
                guard let data = string.data(using: .utf8) else {
                    self?.messagesContinuation.finish(throwing: WebSocketError.cannotParseMessage(string))
                    return
                }

                self?.messagesContinuation.yield(data)
                self?.receive()

            case .failure(let error):
                self?.messagesContinuation.finish(throwing: error)

            default:
                break
            }
        }
    }

    private func handleDisconnect(withError error: Error?) {
        state = .disconnected
        messagesContinuation.finish(throwing: error)
        socketTaskDelegate = nil
    }
}

private class SocketTaskDelegate: NSObject, URLSessionWebSocketDelegate {
    private let onWebSocketTaskDidOpen: (_ protocol: String?) -> Void
    private let onWebSocketTaskDidClose: (_ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) -> Void
    private let onWebSocketTaskDidCompleteWithError: (_ error: Error?) -> Void

    init(
        onWebSocketTaskDidOpen: @escaping (_: String?) -> Void,
        onWebSocketTaskDidClose: @escaping (_: URLSessionWebSocketTask.CloseCode, _: Data?) -> Void,
        onWebSocketTaskDidCompleteWithError: @escaping (_: Error?) -> Void
    ) {
        self.onWebSocketTaskDidOpen = onWebSocketTaskDidOpen
        self.onWebSocketTaskDidClose = onWebSocketTaskDidClose
        self.onWebSocketTaskDidCompleteWithError = onWebSocketTaskDidCompleteWithError
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        onWebSocketTaskDidOpen(proto)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onWebSocketTaskDidClose(closeCode, reason)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onWebSocketTaskDidCompleteWithError(error)
    }
}
