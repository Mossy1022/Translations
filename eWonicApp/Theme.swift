//
//  Theme.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 6/9/25.
//
import SwiftUI

enum EwonicTheme {
  // Add 'AccentColor' in Assets.xcassets → a bright blue-green (#16C2D5 works well).
    static let accent       = Color("AccentColor")
  static let bgGradient   = LinearGradient(
    gradient: Gradient(colors:[
      Color.black.opacity(0.85),
      Color.black.opacity(0.95)
    ]),
    startPoint: .top,
    endPoint: .bottom
  )

  static let bubbleSent        = Color.blue.opacity(0.12)
  static let bubbleReceived    = Color.green.opacity(0.13)
  static let bubbleTranslated  = Color.purple.opacity(0.14)

  static let pillConnected     = Color.green
  static let pillConnecting    = Color.yellow
  static let pillDisconnected  = Color.orange
}
