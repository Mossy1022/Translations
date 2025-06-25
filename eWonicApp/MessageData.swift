//
//  MessageData.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation

struct MessageData: Codable {
  let id                : UUID
  let text              : String        // raw transcript (no translation)
  let source_language   : String        // BCP-47, e.g. "en-US"
  let is_final          : Bool          // true when end-of-sentence
  let timestamp         : TimeInterval  // wall-clock seconds
}
