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
    public var blockSize: Int = 4096
    public lazy var currentTimeWithMillis = {
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        return dateFormatter.string(from: Date())
    }()

    private let dateFormatter = DateFormatter()
    private var serverConnection: NWConnection?
    private var queue: [Data] = []
    private var dataBuffer = Data()

    public init(serviceName: String? = nil, blockSize: Int? = nil) {
        self.serviceName = serviceName
        if let blockSize {
            self.blockSize = blockSize
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
    
    public func stopClient() {
        sendMessage("Closing...")
        serverConnection?.cancel()
        serverConnection = nil
    }
    
    public func sendMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        sendData(data)
    }
    
    public func sendData(_ data: Data) {
        let length = UInt32(data.count).bigEndian // Get the size
        var header = withUnsafeBytes(of: length) { Data($0) } // Create a header
        let packet = header + data // Append it to the front
        
        if let serverConnection,
           serverConnection.state == .ready {
            serverConnection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.debugLog("Failed to send data: \(error)")
                } else {
                    self?.debugLog("Data sent successfully (\(packet.count) bytes).")
                }
            })
        } else {
            debugLog("Client is not ready. Queuing data (\(packet.count) bytes).")
            queue.append(packet)
        }
    }
}

// Connection handling
private extension Client {
    func connect(to endpoint: NWEndpoint) {
        serverConnection = NWConnection(to: endpoint, using: .tcp)
        serverConnection?.start(queue: .main)
        guard let serverConnection = self.serverConnection else { return }

        serverConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                debugLog("Connected to server, waiting for data up to \(blockSize) bytes")
                sendMessage("Hello from client! Receiving data up to \(blockSize) bytes")
                listenToStream(on: serverConnection)
            case .failed(let error):
                debugLog("Connection failed: \(error)")
            default:
                break
            }
        }
    }
}

// Listening data from server
private extension Client {
    func listenToStream(on serverConnection: NWConnection) {
        serverConnection.receive(minimumIncompleteLength: 1, maximumLength: blockSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            
            if let data = data {
                self.dataBuffer.append(data)
                
                self.debugLog("Received: \(data.count) byte, total: \(dataBuffer.count) byte")
                while let data = NetworkHelper.completedData(from: &self.dataBuffer),
                      data != nil {
                    self.debugLog("Receive complete, databuffer after cleanup: \(dataBuffer.count) byte")
                    
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
                self.debugLog("Server connection closed")
                serverConnection.cancel()
                self.serverConnection = nil
            } else {
                // Keep receiving
                self.listenToStream(on: serverConnection)
            }
        }
    }
}

extension Client: Hashable, Identifiable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(clientId)
    }

    public static func == (lhs: Client, rhs: Client) -> Bool {
        return lhs.clientId == rhs.clientId
    }
}
