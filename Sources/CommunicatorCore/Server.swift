//
//  Server.swift
//  CommunicatorCore
//
//  Created by Andras Olah on 2024. 12. 25..
//

import Foundation
import Network

open class Server: @unchecked Sendable {
    public var serverId: UUID = UUID()
    public let serviceName: String
    public let serviceType: String
    public let port: UInt16
    public lazy var currentTimeWithMillis = {
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: Date())
    }()

    private let df = DateFormatter()
    private var listener: NWListener?
    private var clients: [ConnectedClient] = []
    private var clientQueues: [ConnectedClient: [Data]] = [:]
    private var dataBuffer = Data()

    public init(serviceName: String,port: UInt16) {
        self.serviceName = serviceName
        self.serviceType = Constants.serviceTypeFormat(serviceName: serviceName)
        self.port = port
        
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port) ?? .any)
        } catch {
            debugLog("Failed to create listener: \(error)")
        }
    }
    
    open func debugLog(_ message: String) {
        #if DEBUG
            print("[SERVER][DEBUG] \(message)")
        #endif
    }

    public func startServer() {
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.debugLog("Server ready on port \(self?.listener?.port?.rawValue ?? 0)")
            case .failed(let error):
                self?.debugLog("Listener failed with error: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.debugLog("New connection received")
            self?.handleConnection(ConnectedClient(connection: connection))
        }

        listener?.start(queue: .main)

        // Publish Bonjour service
        listener?.service = NWListener.Service(name: serviceName, type: serviceType)
    }
        
    public func sendMessage(_ message: String, to clientId: String? = nil) {
        guard let data = message.data(using: .utf8) else { return }
        sendData(data, to: clientId)
    }
    
    public func sendData(_ data: Data, to clientId: String? = nil) {
        if let clientId,
           let client = clients.first(where: { client in
               client.clientId.uuidString == clientId
           }) {
            sendData(data, to: client)
        } else {
            for client in clients {
                sendData(data, to: client)
            }
        }
    }
    
}

private extension Server {
    func startReceiving(on serverConnection: NWConnection) {
        serverConnection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let data = data {
                self.dataBuffer.append(data)
                print("nani, data buffer size: \(self.dataBuffer.count) byte")
                
                // Attempt to parse out complete messages
                while isDataReady(from: &self.dataBuffer) {
                    print("nani, inside while, data buffer size: \(self.dataBuffer.count) byte")
                    // Keep extracting until no complete message remains
                }
            }
            
            if let error = error {
                self.debugLog("Connection error: \(error)")
            }
            if isComplete {
                self.debugLog("Connection closed by peer.")
            } else {
                // Keep receiving
                self.startReceiving(on: serverConnection)
            }
        }
    }
    
    func sendData(_ data: Data, to client: ConnectedClient) {
        let length = UInt32(data.count).bigEndian // Get the size
        var header = withUnsafeBytes(of: length) { Data($0) } // Create a header
        let packet = header + data // Append it to the front
        
        if client.connection.state == .ready {
            client.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.debugLog("Failed to send data: \(error)")
                } else {
                    self?.debugLog("Data sent successfully (\(packet.count) bytes).")
                }
            })
        } else {
            debugLog("Client is not ready. Queuing data (\(packet.count) bytes).")
            clientQueues[client, default: []].append(packet)
        }
    }

    func handleConnection(_ client: ConnectedClient) {
        client.connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                debugLog("Connection is ready. Flushing queued messages if any.")
                if let queuedPackets = self.clientQueues[client] {
                    for packet in queuedPackets {
                        client.connection.send(content: packet, completion: .contentProcessed { error in
                            if let error = error {
                                self.debugLog("Failed to send queued data: \(error)")
                            }
                        })
                    }
                    self.clientQueues[client] = []
                }
            case .failed(let error):
                self.debugLog("Connection failed: \(error)")
            default:
                break
            }
        }

        // Start connection
        client.connection.start(queue: .main)
        startReceiving(on: client.connection)

        // Keep track of the connection
        clients.append(client)
        clientQueues[client] = []
        
        debugLog("Client count: \(clients.count)")

        // Send a welcome message
        sendMessage("Hello from server!", to: client.clientId.uuidString)
    }
}

extension Server: Hashable, Identifiable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(serverId)
    }

    public static func == (lhs: Server, rhs: Server) -> Bool {
        return lhs.serverId == rhs.serverId
    }
}

private extension Server {
    /// Returns true if a complete message was found and removed from `buffer`,
    /// or false if not enough data was available.
    private func isDataReady(from buffer: inout Data) -> Bool {
        // 1) Need at least 4 bytes for the length prefix
        guard buffer.count >= 4 else { return false }
        
        // 2) Read the first 4 bytes to get the payload length
        let lengthField = buffer[0..<4]
        let payloadLength = lengthField.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // 3) Check if the buffer has enough bytes for the full payload
        guard buffer.count >= 4 + Int(payloadLength) else { return false }
        
        // 4) Extract the payload
        let messageData = buffer[4..<(4 + Int(payloadLength))]
        
        // 5) Remove it from the front of the buffer
        buffer.removeSubrange(0..<(4 + Int(payloadLength)))
        
        // 6) Handle the message
        debugLog("Received a complete message: \(messageData.count) bytes")
        handleCompleteMessage(messageData)
        
        return true
    }

    private func handleCompleteMessage(_ data: Data) {
        // For example, try to decode text
        if let text = String(data: data, encoding: .utf8) {
            debugLog("It's a text message: \(text)")
        } else {
            // Possibly detect file type (PNG, PDF, etc.) using your `mimeType(for:)` method
            if let fileType = data.mimeType() {
                debugLog("Received a \(fileType) file (\(data.count) bytes)")
            } else {
                debugLog("Unknown binary data (\(data.count) bytes)")
            }
        }
    }
}


final class ConnectedClient: Hashable, @unchecked Sendable  {
    let clientId: UUID
    let connection: NWConnection

    init(connection: NWConnection) {
        self.clientId = UUID()
        self.connection = connection
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(clientId)
    }

    static func == (lhs: ConnectedClient, rhs: ConnectedClient) -> Bool {
        return lhs.clientId == rhs.clientId
    }
}
