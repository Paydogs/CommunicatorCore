//
//  Client.swift
//  CommunicatorCore
//
//  Created by Andras Olah on 2024. 12. 25..
//

import Foundation
import Network

open class Client: @unchecked Sendable {
    public var clientId: UUID = UUID()
    public var serviceName: String?

    private var connection: NWConnection?

    public init(serviceName: String? = nil) {
        self.serviceName = serviceName
    }
    
    open func debugLog(_ message: String) {
        #if DEBUG
            print("[DEBUG] \(message)")
        #endif
    }

    public func discoverAndConnect(serviceName: String? = nil, serviceDomain: String = "local.") {
        if let serviceName {
            self.serviceName = serviceName
        }
        guard let service = self.serviceName else { return }
        let type = Constants.serviceTypeFormat(serviceName: service)
        debugLog("Starting to browse for \(type)")
        let browser = NWBrowser(for: .bonjour(type: type, domain: serviceDomain), using: .tcp)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            for result in results {
                switch result.endpoint {
                case .service(let name, _, _, _):
                    self.debugLog("Discovered service: \(name)")
                    self.connect(to: result.endpoint)
                default:
                    break
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.debugLog("Waiting for server to show up")
            case .failed(let error):
                self?.debugLog("Cannot start finding services: \(error)")
            default:
                break
            }
        }

        browser.start(queue: .main)
    }

    private func connect(to endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.start(queue: .main)
        guard let connection = self.connection else { return }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                debugLog("Connected to server")
                sendMessage("Hello from client!")
                startReceiving(on: connection)
            case .failed(let error):
                debugLog("Connection failed: \(error)")
            default:
                break
            }
        }

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

    public func sendMessage(_ message: String) {
        debugLog("sending message: \(message)")
        if connection?.state == .ready {
            connection?.send(content: message.data(using: .utf8), completion: .contentProcessed { [weak self] error in
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

extension Client: Hashable {
    // Conform to Hashable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(clientId)
    }

    // Conform to Equatable
    public static func == (lhs: Client, rhs: Client) -> Bool {
        return lhs.clientId == rhs.clientId
    }
}
