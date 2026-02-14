import Foundation

final class FederationClient: NSObject, URLSessionWebSocketDelegate {
    private let eventBus: EventBus
    private let core: BridgeCore
    private let configStore: ConfigStore
    private let logger: AppLogger

    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var eventSubscriptionID: UUID?
    private var shouldRun = false

    init(eventBus: EventBus, core: BridgeCore, configStore: ConfigStore, logger: AppLogger) {
        self.eventBus = eventBus
        self.core = core
        self.configStore = configStore
        self.logger = logger
    }

    func start() {
        shouldRun = true
        reconnectAttempts = 0
        logger.log(.info, "FederationClient start requested")
        emitStatus(state: "start", detail: "client start requested")
        connectIfNeeded()
    }

    func stop() {
        shouldRun = false
        if let id = eventSubscriptionID {
            eventBus.unsubscribe(id)
            eventSubscriptionID = nil
        }
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        session?.invalidateAndCancel()
        session = nil
        emitStatus(state: "stopped", detail: "client stopped")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        reconnectAttempts = 0
        logger.log(.info, "FederationClient connected")
        emitStatus(state: "connected", detail: "websocket connected")
        sendHello()
        subscribeEventsIfNeeded()
        receiveLoop()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        logger.log(.warning, "FederationClient closed: \(closeCode.rawValue)")
        emitStatus(state: "closed", detail: "close_code=\(closeCode.rawValue)")
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            logger.log(.warning, "FederationClient error: \(error.localizedDescription)")
            emitStatus(state: "error", detail: "task_error=\(error.localizedDescription)")
        }
        scheduleReconnect()
    }

    private func connectIfNeeded() {
        guard shouldRun else { return }
        let cfg = configStore.load()
        guard cfg.federationEnabled else {
            logger.log(.info, "FederationClient disabled by config")
            emitStatus(state: "disabled", detail: "federation disabled in config")
            return
        }
        guard let url = URL(string: cfg.federationURL), !cfg.federationURL.isEmpty else {
            logger.log(.warning, "FederationClient disabled: federationURL is empty or invalid")
            emitStatus(state: "invalid_url", detail: "federationURL is empty or invalid")
            return
        }
        logger.log(.info, "FederationClient connecting to \(cfg.federationURL)")
        emitStatus(state: "connecting", detail: cfg.federationURL)

        var request = URLRequest(url: url)
        let token = cfg.federationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.socketTask = task
        task.resume()
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        reconnectAttempts += 1
        let maxDelay = Double(configStore.load().federationReconnectMaxSeconds)
        let delay = min(pow(2.0, Double(min(reconnectAttempts, 6))), maxDelay)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connectIfNeeded()
        }
    }

    private func sendHello() {
        let hello = FederationEnvelope(
            type: "hello",
            timestamp: FederationMessage.now(),
            payload: FederationHelloPayload(version: "0.1.0", capabilities: ["line", "tmux"])
        )
        send(hello)
    }

    private func subscribeEventsIfNeeded() {
        guard eventSubscriptionID == nil else { return }
        eventSubscriptionID = eventBus.subscribe { [weak self] event in
            guard let self else { return }
            if event.payload["_from_federation"] == "1" { return }
            // Skip forwarding our own federation_status events to prevent echo noise
            if event.type == "federation_status" { return }
            let message = FederationEnvelope(
                type: "event",
                timestamp: FederationMessage.now(),
                payload: FederationEventPayload(event: event)
            )
            self.send(message)
        }
    }

    private func receiveLoop() {
        socketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text: text)
                } else if case .data(let data) = message,
                          let text = String(data: data, encoding: .utf8) {
                    self.handle(text: text)
                }
                self.receiveLoop()
            case .failure(let error):
                self.logger.log(.warning, "FederationClient receive failed: \(error.localizedDescription)")
                self.emitStatus(state: "receive_failed", detail: error.localizedDescription)
                self.socketTask?.cancel(with: .goingAway, reason: nil)
                self.socketTask = nil
                self.session?.invalidateAndCancel()
                self.session = nil
                self.scheduleReconnect()
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        if type == "ping" {
            let pong = FederationEnvelope(type: "pong", timestamp: FederationMessage.now(), payload: ["ok": true])
            send(pong)
            return
        }

        if type == "event",
           let payloadObj = json["payload"] as? [String: Any],
           let eventObj = payloadObj["event"] as? [String: Any],
           let adapter = eventObj["adapter"] as? String,
           let eventType = eventObj["type"] as? String {
            let rawPayload = eventObj["payload"] as? [String: Any] ?? [:]
            var payload: [String: String] = [:]
            payload.reserveCapacity(rawPayload.count + 1)
            for (key, value) in rawPayload {
                if let stringValue = value as? String {
                    payload[key] = stringValue
                } else if let numberValue = value as? NSNumber {
                    payload[key] = numberValue.stringValue
                } else if let boolValue = value as? Bool {
                    payload[key] = boolValue ? "true" : "false"
                } else {
                    payload[key] = String(describing: value)
                }
            }
            let project = payload["project"] ?? payload["conversation"] ?? "-"
            let source = payload["source"] ?? "-"

            // Mode resolution: local config overrides, then trust the server's event mode
            if adapter == "tmux" {
                let sessionType = payload["session_type"] ?? "claude_code"
                let localMode = configStore.load().tmuxSessionModes[AppConfig.modeKey(sessionType: sessionType, project: project)]  // nil = not configured
                let eventMode = payload["mode"] ?? "ignore"
                let effectiveMode = localMode ?? eventMode  // local config wins if set, otherwise trust remote
                if effectiveMode == "ignore" {
                    logger.log(.debug, "FederationClient: dropping ignored tmux event for \(project) (local=\(localMode ?? "nil") event=\(eventMode))")
                    return
                }
            }

            payload["_from_federation"] = "1"
            _ = eventBus.append(type: eventType, adapter: adapter, payload: payload)
            logger.log(.info, "FederationClient received event: \(adapter).\(eventType) project=\(project) source=\(source)")
            return
        } else if type == "event" {
            logger.log(.warning, "FederationClient received malformed event payload")
            return
        }

        if type == "command",
           let payload = json["payload"] as? [String: Any],
           let id = payload["id"] as? String,
           let method = payload["method"] as? String,
           let path = payload["path"] as? String {
            let headers = payload["headers"] as? [String: String] ?? [:]
            let body = payload["body"] as? String
            let command = FederationCommandPayload(
                id: id,
                method: method,
                path: path,
                headers: headers,
                body: body
            )
            let response = core.handleFederationCommand(command)
            let envelope = FederationEnvelope(
                type: "response",
                timestamp: FederationMessage.now(),
                payload: response
            )
            send(envelope)
        }
    }

    private func send<T: Codable>(_ payload: T) {
        guard let socketTask else { return }
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        socketTask.send(.string(text)) { [weak self] error in
            if let error {
                self?.logger.log(.warning, "FederationClient send failed: \(error.localizedDescription)")
                self?.emitStatus(state: "send_failed", detail: error.localizedDescription)
            }
        }
    }

    private func emitStatus(state: String, detail: String) {
        _ = eventBus.append(
            type: "federation_status",
            adapter: "federation",
            payload: [
                "state": state,
                "detail": String(detail.prefix(160)),
            ]
        )
    }
}
