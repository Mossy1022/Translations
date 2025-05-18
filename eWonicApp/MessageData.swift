//
//  MessageData.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation

struct MessageData: Codable {
    let id: UUID
    let originalText: String
    let sourceLanguageCode: String // e.g., "en-US" (BCP-47)
    let targetLanguageCode: String // e.g., "es-ES" (BCP-47)
}
