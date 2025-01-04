//
//  Client.swift
//  CommunicatorCore
//
//  Created by Andras Olah on 2024. 12. 25..
//

import Foundation
import Network
import UniformTypeIdentifiers

open class Client: @unchecked Sendable {
    public var clientId: UUID = UUID()
    public var serviceName: String?
    public var maxDataLength: Int = 1024

    private var serverConnection: NWConnection?
    private var dataBuffer = Data()

    public init(serviceName: String? = nil, maxDataLength: Int? = nil) {
        self.serviceName = serviceName
        if let maxDataLength {
            self.maxDataLength = maxDataLength
        }
    }
    
    open func debugLog(_ message: String) {
        #if DEBUG
            print("[CLIENT][DEBUG] \(message)")
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
        serverConnection = NWConnection(to: endpoint, using: .tcp)
        serverConnection?.start(queue: .main)
        guard let serverConnection = self.serverConnection else { return }

        serverConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                debugLog("Connected to server, waiting for data up to \(maxDataLength) bytes")
                sendMessage("Hello from client! Receiving data up to \(maxDataLength) bytes")
                startReceiving(on: serverConnection)
            case .failed(let error):
                debugLog("Connection failed: \(error)")
            default:
                break
            }
        }
    }
    
    func startReceiving(on serverConnection: NWConnection) {
        serverConnection.receive(minimumIncompleteLength: 1, maximumLength: maxDataLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let data = data {
                self.dataBuffer.append(data)
                
                // Attempt to parse out complete messages
                while parseOneMessage(from: &self.dataBuffer) {
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

    public func sendMessage(_ message: String) {
        debugLog("sending message: \(message)")
        if serverConnection?.state == .ready {
            serverConnection?.send(content: message.data(using: .utf8), completion: .contentProcessed { [weak self] error in
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
    public func hash(into hasher: inout Hasher) {
        hasher.combine(clientId)
    }

    public static func == (lhs: Client, rhs: Client) -> Bool {
        return lhs.clientId == rhs.clientId
    }
}

private extension Client {
    /// Returns true if a complete message was found and removed from `buffer`,
    /// or false if not enough data was available.
    private func parseOneMessage(from buffer: inout Data) -> Bool {
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
