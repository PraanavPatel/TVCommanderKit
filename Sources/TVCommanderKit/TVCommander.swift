//
//  TVCommander.swift
//
//
//  Created by Wilson Desimini on 9/3/23.
//

import Foundation
import Starscream

public protocol TVCommanderDelegate: AnyObject {
    func tvCommanderDidConnect(_ tvCommander: TVCommander)
    func tvCommanderDidDisconnect(_ tvCommander: TVCommander)
    func tvCommander(_ tvCommander: TVCommander, didUpdateAuthState authStatus: TVAuthStatus)
    func tvCommander(_ tvCommander: TVCommander, didWriteRemoteCommand command: TVRemoteCommand)
    func tvCommander(_ tvCommander: TVCommander, didEncounterError error: TVCommanderError)
}

public class TVCommander: WebSocketDelegate, CertificatePinning {
    public weak var delegate: TVCommanderDelegate?
    private(set) public var tvConfig: TVConnectionConfiguration
    private(set) public var authStatus = TVAuthStatus.none
    private(set) public var isConnected = false
    private var webSocket: WebSocket?

    public init(tvIPAddress: String, appName: String, authToken: TVAuthToken? = nil) {
        tvConfig = TVConnectionConfiguration(
            app: appName,
            path: "/api/v2/channels/samsung.remote.control",
            ipAddress: tvIPAddress,
            port: 8002,
            scheme: "wss",
            token: authToken
        )
    }

    // MARK: Establish WebSocket Connection

    public func connectToTV() {
        guard !isConnected else {
            handleError(.connectionAlreadyEstablished)
            return
        }
        guard let url = buildTVURL() else {
            handleError(.urlConstructionFailed)
            return
        }
        setupWebSocket(with: url)
    }

    private func buildTVURL() -> URL? {
        var components = URLComponents()
        components.path = tvConfig.path
        components.host = tvConfig.ipAddress
        components.port = tvConfig.port
        components.scheme = tvConfig.scheme
        var queryItems = [URLQueryItem]()
        tvConfig.app.asBase64.flatMap { queryItems.append(.init(name: "name", value: $0)) }
        tvConfig.token.flatMap { queryItems.append(.init(name: "token", value: $0)) }
        components.queryItems = queryItems
        return components.url
    }

    private func setupWebSocket(with url: URL) {
        let request = URLRequest(url: url)
        webSocket = createWebSocket(with: request)
        webSocket?.respondToPingWithPong = true
        webSocket?.delegate = self
        webSocket?.connect()
    }

    private func createWebSocket(with request: URLRequest) -> WebSocket {
        WebSocket(request: request, certPinner: self)
    }

    // MARK: Interact with WebSocket

    public func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected:
            handleWebSocketConnected()
        case .cancelled, .disconnected:
            handleWebSocketDisconnected()
        case .text(let text):
            handleWebSocketText(text)
        case .binary(let data):
            handleWebSocketBinary(data)
        case .error(let error):
            handleError(.webSocketError(error))
        default:
            break
        }
    }

    public func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ())) {
        completion(.success)
    }

    private func handleWebSocketConnected() {
        isConnected = true
        delegate?.tvCommanderDidConnect(self)
    }

    private func handleWebSocketDisconnected() {
        isConnected = false
        authStatus = .none
        webSocket = nil
        delegate?.tvCommanderDidDisconnect(self)
    }

    private func handleWebSocketText(_ text: String) {
        if let packetData = text.asData {
            webSocketDidReadPacket(packetData)
        } else {
            handleError(.packetDataParsingFailed)
        }
    }

    private func handleWebSocketBinary(_ data: Data) {
        webSocketDidReadPacket(data)
    }

    private func webSocketDidReadPacket(_ packet: Data) {
        if let authResponse = parseAuthResponse(from: packet) {
            handleAuthResponse(authResponse)
        } else {
            handleError(.packetDataParsingFailed)
        }
    }

    // MARK: Receive Auth

    private func parseAuthResponse(from packet: Data) -> TVAuthResponse? {
        let decoder = JSONDecoder()
        let authResponseType = TVResponse<TVAuthResponseBody>.self
        return try? decoder.decode(authResponseType, from: packet)
    }

    private func handleAuthResponse(_ response: TVAuthResponse) {
        switch response.event {
        case .connect:
            handleAuthAllowed(response)
        case .unauthorized:
            handleAuthDenied(response)
        case .timeout:
            handleAuthCancelled(response)
        default:
            handleError(.authResponseUnexpectedChannelEvent(response))
        }
    }

    private func handleAuthAllowed(_ response: TVAuthResponse) {
        authStatus = .allowed
        delegate?.tvCommander(self, didUpdateAuthState: authStatus)
        if let newToken = response.data?.token {
            tvConfig.token = newToken
        } else if let refreshedToken = response.data?.clients.first(
            where: { $0.attributes.name == tvConfig.app.asBase64 })?.attributes.token {
            tvConfig.token = refreshedToken
        } else {
            handleError(.noTokenInAuthResponse(response))
        }
    }

    private func handleAuthDenied(_ response: TVAuthResponse) {
        authStatus = .denied
        delegate?.tvCommander(self, didUpdateAuthState: authStatus)
    }

    private func handleAuthCancelled(_ response: TVAuthResponse) {
        authStatus = .none
        delegate?.tvCommander(self, didUpdateAuthState: authStatus)
    }

    // MARK: Send Remote Control Commands

    public func sendRemoteCommand(key: TVRemoteCommand.Params.ControlKey) {
        guard isConnected else {
            handleError(.remoteCommandNotConnectedToTV)
            return
        }
        guard authStatus == .allowed else {
            handleError(.remoteCommandAuthenticationStatusNotAllowed)
            return
        }
        sendCommandOverWebSocket(createRemoteCommand(key: key))
    }

    private func createRemoteCommand(key: TVRemoteCommand.Params.ControlKey) -> TVRemoteCommand {
        let params = TVRemoteCommand.Params(cmd: .click, dataOfCmd: key, option: false, typeOfRemote: .remoteKey)
        return TVRemoteCommand(method: .control, params: params)
    }

    private func sendCommandOverWebSocket(_ command: TVRemoteCommand) {
        guard let commandStr = try? command.asString() else {
            handleError(.commandConversionToStringFailed)
            return
        }
        webSocket?.write(string: commandStr) { [weak self] in
            guard let self else { return }
            self.delegate?.tvCommander(self, didWriteRemoteCommand: command)
        }
    }

    // MARK: Disconnect WebSocket Connection

    public func disconnectFromTV() {
        webSocket?.disconnect()
    }

    // MARK: Handler Errors

    private func handleError(_ error: TVCommanderError) {
        delegate?.tvCommander(self, didEncounterError: error)
    }
}
