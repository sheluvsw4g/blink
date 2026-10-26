// Socket Service - Real-time communication via Socket.io
import Foundation
import Combine

// Simple Socket.io client implementation
// In production, consider using Socket.IO-Client-Swift library

final class SocketService: ObservableObject {
    static let shared = SocketService()
    
    @Published var connectionState: AppState.ConnectionState = .disconnected
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let baseReconnectDelay: TimeInterval = 2
    
    // Event handlers
    private var eventHandlers: [String: [(Data) -> Void]] = [:]
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    
    private init() {
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }
    
    func connect(token: String) async {
        guard webSocketTask?.state != .running else { return }
        
        await MainActor.run {
            connectionState = .connecting
        }
        
        // TODO: Change to your backend WebSocket URL
        #if DEBUG
        let wsURL = "ws://192.168.0.76:3000/socket.io/?token=\(token)&transport=websocket"
        #else
        let wsURL = "ws://192.168.0.76:3000/socket.io/?token=\(token)&transport=websocket"
        #endif
        
        guard let url = URL(string: wsURL) else {
            await updateState(.failed(APIError.invalidURL))
            return
        }
        
        urlSession = URLSession(configuration: .default)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        await receiveMessage()
        startPing()
        
        // Send initial connection packet (Socket.io protocol)
        await sendSocketIOPacket(type: 0, data: "") // CONNECT
    }
    
    func disconnect() async {
        pingTimer?.invalidate()
        pingTimer = nil
        
        await sendSocketIOPacket(type: 1, data: "") // DISCONNECT
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        reconnectAttempts = 0
        
        await updateState(.disconnected)
    }
    
    private func receiveMessage() async {
        guard let task = webSocketTask else { return }
        
        do {
            let message = try await task.receive()
            await handleMessage(message)
            await receiveMessage() // Continue listening
        } catch {
            await handleDisconnect(error: error)
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            await handleTextMessage(text)
        case .data(let data):
            await handleBinaryMessage(data)
        @unknown default:
            break
        }
    }
    
    private func handleTextMessage(_ text: String) async {
        // Socket.io protocol: <packet_type>[<data>]
        // Packet types: 0=CONNECT, 1=DISCONNECT, 2=EVENT, 3=ACK, 4=ERROR, 5=BINARY_EVENT, 6=BINARY_ACK
        
        if text.hasPrefix("0") {
            // Connected
            await updateState(.connected)
            reconnectAttempts = 0
            print("Socket connected")
        } else if text.hasPrefix("40") {
            // Connection established (namespace)
            print("Socket namespace connected")
        } else if text.hasPrefix("2") || text.hasPrefix("5") {
            // Event or Binary Event
            let payload = String(text.dropFirst())
            await parseSocketIOEvent(payload)
        } else if text.hasPrefix("3") || text.hasPrefix("6") {
            // ACK - ignore for now
        } else if text.hasPrefix("4") {
            // Error
            let errorPayload = String(text.dropFirst())
            print("Socket error: \(errorPayload)")
        }
    }
    
    private func handleBinaryMessage(_ data: Data) async {
        // Handle binary messages if needed
    }
    
    private func parseSocketIOEvent(_ payload: String) async {
        // Format: [<event_name>, <data>] or [<event_name>, <data>, <ack_id>]
        guard let data = payload.data(using: .utf8) else { return }
        
        do {
            let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any]
            guard jsonArray?.count ?? 0 >= 2,
                  let eventName = jsonArray?[0] as? String else { return }
            
            let eventData = jsonArray?[1]
            let eventDataJSON = try JSONSerialization.data(withJSONObject: eventData ?? [])
            
            await MainActor.run {
                // Call registered handlers
                eventHandlers[eventName]?.forEach { handler in
                    handler(eventDataJSON)
                }
                
                // Also call wildcard handlers
                eventHandlers["*"]?.forEach { handler in
                    handler(eventDataJSON)
                }
            }
        } catch {
            print("Failed to parse socket event: \(error)")
        }
    }
    
    private func handleDisconnect(error: Error?) async {
        await updateState(.disconnected)
        print("Socket disconnected: \(error?.localizedDescription ?? "unknown")")
        
        // Attempt reconnection
        if reconnectAttempts < maxReconnectAttempts {
            await updateState(.reconnecting)
            let delay = baseReconnectDelay * pow(2, Double(reconnectAttempts))
            reconnectAttempts += 1
            
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            if let token = await AppState.shared.accessToken {
                await connect(token: token)
            }
        } else {
            await updateState(.failed(error ?? APIError.unknown))
        }
    }
    
    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { await self?.sendPing() }
        }
    }
    
    private func sendPing() async {
        await sendSocketIOPacket(type: 2, data: "[\"ping\",{}]")
    }
    
    private func sendSocketIOPacket(type: Int, data: String) async {
        let packet = "\(type)\(data)"
        await send(packet)
    }
    
    func emit(_ event: String, _ data: any Codable) async {
        let payload = try? encoder.encode([event, data])
        let payloadString = payload.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        await sendSocketIOPacket(type: 2, data: payloadString)
    }
    
    // Convenience emit for dictionary payloads
    func emitDict(_ event: String, _ data: [String: Any]) async {
        var payload: [Any] = [event]
        if let jsonData = try? JSONSerialization.data(withJSONObject: data),
           let json = try? JSONSerialization.jsonObject(with: jsonData) {
            payload.append(json)
        }
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            await sendSocketIOPacket(type: 2, data: payloadString)
        }
    }
    
    func on(_ event: String, handler: @escaping (Data) -> Void) {
        eventHandlers[event, default: []].append(handler)
    }
    
    func off(_ event: String) {
        eventHandlers.removeValue(forKey: event)
    }
    
    private func send(_ text: String) async {
        guard let task = webSocketTask, task.state == .running else { return }
        do {
            try await task.send(.string(text))
        } catch {
            print("Failed to send socket message: \(error)")
        }
    }
    
    private func updateState(_ state: AppState.ConnectionState) async {
        await MainActor.run {
            self.connectionState = state
        }
    }
    
    // Convenience methods for common events
    func joinConversation(_ conversationId: String) async {
        await emit("join:conversation", conversationId)
    }
    
    func leaveConversation(_ conversationId: String) async {
        await emit("leave:conversation", conversationId)
    }
    
    func sendTypingStart(_ conversationId: String) async {
        await emit("typing:start", conversationId)
    }
    
    func sendTypingStop(_ conversationId: String) async {
        await emit("typing:stop", conversationId)
    }
    
    func sendReadReceipt(conversationId: String, messageIds: [String]) async {
        await emitDict("messages:read", ["conversationId": conversationId, "messageIds": messageIds])
    }
    
    func updateStatus(_ status: String) async {
        await emit("status:update", status)
    }
    
    func initiateCall(callId: String, offer: String, conversationId: String, receiverId: String, type: String) async {
        await emit("call:initiate", [
            "callId": callId,
            "offer": offer,
            "conversationId": conversationId,
            "receiverId": receiverId,
            "type": type
        ])
    }
    
    func answerCall(callId: String, answer: String) async {
        await emit("call:answer", ["callId": callId, "answer": answer])
    }
    
    func rejectCall(callId: String) async {
        await emit("call:reject", ["callId": callId])
    }
    
    func endCall(callId: String) async {
        await emit("call:end", ["callId": callId])
    }
    
    func sendIceCandidate(callId: String, candidate: String, targetId: String) async {
        await emit("call:ice-candidate", ["callId": callId, "candidate": candidate, "targetId": targetId])
    }
}