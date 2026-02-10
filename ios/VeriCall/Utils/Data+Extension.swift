//
//  Data+Extension.swift
//  VeriCall
//
//  Data extensions for multipart form data
//

import Foundation

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
