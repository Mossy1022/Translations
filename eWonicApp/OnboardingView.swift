//
//  OnboardingView.swift
//  eWonicApp
//

import SwiftUI

@MainActor
struct OnboardingView: View {
//  @AppStorage("hasSeenOnboarding") private var done = false
    @State private var done = false
    
    /// Returns the decorative image only if it actually exists
    private var wallpaper: some View {
      Group {
        if UIImage(named: "OnboardingBG") != nil {
          Image("OnboardingBG")
            .resizable()
            .scaledToFill()
            .opacity(0.25)
        }
      }
    }

    
  var body: some View {
    if done {
      MainShell()                         // ⬅️ still uses MainShell
    } else {
      VStack(spacing: 40) {
        Spacer()
        Image(systemName: "globe")
          .font(.system(size: 80, weight: .light))
          .foregroundStyle(EwonicTheme.accent)

        Text("Break language barriers instantly.")
          .multilineTextAlignment(.center)
          .font(.largeTitle.weight(.semibold))
          .padding(.horizontal, 30)

        VStack(alignment: .leading, spacing: 18) {
          Label("Hands-free, real-time speech", systemImage: "waveform")
          Label("Auto-discovers nearby users", systemImage: "antenna.radiowaves.left.and.right")
          Label("No special hardware required", systemImage: "headphones")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .labelStyle(.titleAndIcon)
        .foregroundColor(.white.opacity(0.9))

        Spacer()

        Button("Start") { done = true }
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding()
          .background(EwonicTheme.accent)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .padding(.horizontal, 40)

        Spacer().frame(height: 30)
      }
      .background(
        ZStack {
          EwonicTheme.bgGradient
          Image("OnboardingBG")   // optional decorative asset
            .resizable()
            .scaledToFill()
            .opacity(0.25)
        }
        .ignoresSafeArea()
      )
      .foregroundColor(.white)
      .transition(.opacity.combined(with: .move(edge: .bottom)))
      .animation(.easeInOut, value: done)
    }
  }
}
