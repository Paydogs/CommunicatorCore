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
    private var connections: [NWConnection] = []

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
            print("[DEBUG] \(message)")
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
            self?.handleConnection(connection)
        }

        listener?.start(queue: .main)

        // Publish Bonjour service
        listener?.service = NWListener.Service(name: serviceName, type: serviceType)
    }
    
    public func sendMessage(_ message: String) {
        for connection in connections {
            debugLog("sending \(message) through \(connection)")
            
            if connection.state == .ready {
                connection.send(content: message.data(using: .utf8), completion: .contentProcessed { [weak self] error in
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
}

private extension Server {
    func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        startReceiving(on: connection)
        connections.append(connection)
        debugLog("Connection count: \(connections.count)")

        let welcomeMessage = "Hello from server!"
        connection.send(content: welcomeMessage.data(using: .utf8), completion: .contentProcessed({ [weak self] error in
            if let error = error {
                self?.debugLog("Failed to send message: \(error)")
            }
        }))
    }
    
    func startReceiving(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if let data = data, let message = String(data: data, encoding: .utf8) {
                self?.debugLog("Received message: \(message)")
            }

            if let error = error {
                self?.debugLog("Connection error: \(error)")
            }

            if isComplete {
                self?.debugLog("Connection closed by peer.")
            } else {
                self?.startReceiving(on: connection) // Continue listening
            }
        }
    }
}

extension Server: Hashable {
    // Conform to Hashable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(serverId)
    }

    // Conform to Equatable
    public static func == (lhs: Server, rhs: Server) -> Bool {
        return lhs.serverId == rhs.serverId
    }
}
