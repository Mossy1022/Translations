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
    TabView {
      ContentView()
        .tabItem { Label("Peer", systemImage: "person.2") }

      Text("One Phone")
        .tabItem { Label("One Phone", systemImage: "phone") }

      ConventionView()
        .tabItem { Label("Convention", systemImage: "speaker.wave.2") }
    }
  }
}
