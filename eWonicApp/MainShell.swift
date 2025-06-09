//
//  MainShell.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 6/9/25.
//

import SwiftUI

@MainActor
struct MainShell: View {
  var body: some View {
    if #available(iOS 18.4, *) {
      ContentView()
    } else {
      Text("iOS 18.4 or later required")
        .padding()
    }
  }
}
