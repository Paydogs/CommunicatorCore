//
//  Common.swift
//  CommunicatorCore
//
//  Created by Andras Olah on 2024. 12. 25..
//

struct Constants {
    static func serviceTypeFormat(serviceName: String) -> String {
        "_\(serviceName)._tcp"
    }
}
