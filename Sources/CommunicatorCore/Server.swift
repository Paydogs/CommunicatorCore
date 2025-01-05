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
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        return dateFormatter.string(from: Date())
    }()

    private let dateFormatter = DateFormatter()
    private var listener: NWListener?
    private var clients: [ConnectedClient] = []
    private var clientQueues: [ConnectedClient: [Data]] = [:]

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
    
    public func stopServer() {
        sendMessage("Stopping server")
        clients.forEach { client in
            client.connection.cancel()
        }
        clients = []
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

// Connection handling
private extension Server {
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
        listenToStream(from: client)

        // Keep track of the connection
        clients.append(client)
        clientQueues[client] = []
        
        debugLog("Client count: \(clients.count)")

        // Send a welcome message
        sendMessage("Hello from server!", to: client.clientId.uuidString)
    }
}

// Sending data to clients
private extension Server {
    func sendData(_ data: Data, to client: ConnectedClient) {
        let length = UInt32(data.count).bigEndian // Get the size
        var header = withUnsafeBytes(of: length) { Data($0) } // Create a header
        let packet = header + data // Append it to the front
        let clientIndex = clients.firstIndex(of: client) ?? 0
        
        if client.connection.state == .ready {
            client.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.debugLog("Failed to send data: \(error)")
                } else {
                    self?.debugLog("Data sent successfully (\(packet.count) bytes) to Client #\(clientIndex)")
                }
            })
        } else {
            debugLog("Client is not ready. Queuing data (\(packet.count) bytes).")
            clientQueues[client, default: []].append(packet)
        }
    }
}

// Listening data from clients
private extension Server {
    func listenToStream(from client: ConnectedClient) {
        let clientIndex = clients.firstIndex(of: client) ?? 0
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1000 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let data = data {
                client.dataBuffer.append(data)
                
                self.debugLog("Received: \(data.count) byte, total: \(client.dataBuffer.count) byte from Client #\(clientIndex)")
                while let data = NetworkHelper.completedData(from: &client.dataBuffer),
                      data != nil {
                    self.debugLog("Receive from Client #\(clientIndex) is complete, databuffer after cleanup: \(client.dataBuffer.count) byte")
                    
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
            
            if let error = error {
                self.debugLog("Connection error: \(error)")
            }
            if isComplete {
                self.debugLog("Connection to Client #\(clientIndex) closed")
                clients.removeAll { closedClient in
                    client.clientId == closedClient.clientId
                }
            } else {
                // Keep receiving
                self.listenToStream(from: client)
            }
        }
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

final class ConnectedClient: Hashable, @unchecked Sendable  {
    let clientId: UUID
    let connection: NWConnection
    var dataBuffer: Data = Data()

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
