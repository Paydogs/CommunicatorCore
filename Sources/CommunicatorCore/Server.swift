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
    
    public func sendMessage(_ message: String) {
        for client in clients {
            debugLog("Sending \(message) to \(client.clientId)")
            
            if client.connection.state == .ready {
                client.connection.send(content: message.data(using: .utf8), completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        self?.debugLog("Failed to send message: \(error)")
                    } else {
                        self?.debugLog("Message sent successfully.")
                    }
                })
            } else {
                debugLog("Connection is not ready to send messages.")
            }
        }
    }
    
    public func sendData(_ data: Data) {
        debugLog("Queueing data (\(data.count) bytes) for \(clients.count) clients.")
        for client in clients {
            sendFramedData(data, to: client)
        }
    }
    
    func sendFramedData(_ data: Data, to client: ConnectedClient) {
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
}

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
//        startReceiving(on: client)

        // Keep track of the connection
        clients.append(client)
        clientQueues[client] = []
        
        debugLog("Client count: \(clients.count)")

        // Send a welcome message
        let welcomeMessage = "Hello from server!"
        sendFramedData(welcomeMessage.data(using: .utf8)!, to: client)
    }
    
//    func startReceiving(on client: ConnectedClient) {
//        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
//            if let data = data,
//               let message = String(data: data, encoding: .utf8) {
//                    self?.debugLog("Received message: \(message)")
//            }
//
//            if let error = error {
//                self?.debugLog("Connection error: \(error)")
//            }
//
//            if isComplete {
//                self?.debugLog("Connection closed by peer.")
//            } else {
//                self?.startReceiving(on: connection) // Continue listening
//            }
//        }
//    }
}

extension Server: Hashable {
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
