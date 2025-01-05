//
//  Common.swift
//  CommunicatorCore
//
//  Created by Andras Olah on 2024. 12. 25..
//

import Foundation

struct Constants {
    static func serviceTypeFormat(serviceName: String) -> String {
        "_\(serviceName)._tcp"
    }
}

struct NetworkHelper {
    static func completedData(from buffer: inout Data) -> Data? {
        guard buffer.count >= 4 else {
            // Too small to have a header
            return nil }
        
        let lengthField = buffer[0..<4]
        let payloadLength = lengthField.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard buffer.count >= 4 + Int(payloadLength) else {
            // Not all received
            return nil
        }
        
        let messageData = buffer[4..<(4 + Int(payloadLength))]
        
        // 5) Remove it from the front of the buffer
        buffer.removeSubrange(0..<(4 + Int(payloadLength)))
        
        return messageData
    }
}

extension Data {
    func mimeType() -> String? {
        var bytes = [UInt8](repeating: 0, count: 1)
        self.copyBytes(to: &bytes, count: 1)
        
        switch bytes {
            // JPEG: FF D8 FF
            case _ where bytes.starts(with: [0xFF, 0xD8, 0xFF]):
                return "image/jpeg"
                
            // PNG: 89 50 4E 47
            case _ where bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]):
                return "image/png"
                
            // GIF: 47 49 46 38 (GIF87a or GIF89a)
            case _ where bytes.starts(with: [0x47, 0x49, 0x46, 0x38]):
                return "image/gif"
                
            // PDF: 25 50 44 46
            case _ where bytes.starts(with: [0x25, 0x50, 0x44, 0x46]):
                return "application/pdf"
                
            // ZIP: 50 4B 03 04 (also used by .docx, .xlsx, .apk, etc.)
            case _ where bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]):
                return "application/zip"
                
            // RAR: 52 61 72 21
            case _ where bytes.starts(with: [0x52, 0x61, 0x72, 0x21]):
                return "application/x-rar-compressed"
                
            // 7z: 37 7A BC AF 27 1C
            case _ where bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]):
                return "application/x-7z-compressed"
                
            // GZIP: 1F 8B 08
            case _ where bytes.starts(with: [0x1F, 0x8B, 0x08]):
                return "application/gzip"
                
            // BMP: 42 4D
            case _ where bytes.starts(with: [0x42, 0x4D]):
                return "image/bmp"
        default:   return nil
        }
    }
}
