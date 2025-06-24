//
//  Log.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 6/23/25.
//


import os.log

/// Lightweight debug logger that disappears in release builds.
enum Log {
  private static let log = Logger(subsystem: "com.evansoasis.ewonic", category: "general")

  static func d(_ msg: String) {
    #if DEBUG
    log.debug("\(msg, privacy: .public)")
    #endif
  }
}
