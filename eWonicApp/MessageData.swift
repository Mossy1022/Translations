//
//  MessageData.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation

struct MessageData: Codable {
  let id                  : UUID
  let text                : String           // raw transcript
  let source_language_code: String           // e.g. "en-US"
  let is_final            : Bool             // true when sentence finished
  let timestamp           : TimeInterval     // epoch seconds
}
