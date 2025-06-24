import SwiftUI

@MainActor
struct OnboardingView: View {
  @State private var done            = false
  @State private var wallpaperImage  : Image?
  @State private var isLoadingImage  = true

  var body: some View {
    Group {
      if done {
        MainShell()                                // main app
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
            Label("Hands-free, real-time speech",       systemImage: "waveform")
            Label("Auto-discovers nearby users",        systemImage: "antenna.radiowaves.left.and.right")
            Label("No special hardware required",       systemImage: "headphones")
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
            .disabled(isLoadingImage)               // never blocks now

          if isLoadingImage {
            ProgressView().progressViewStyle(.circular)
              .tint(.white.opacity(0.7))
              .padding(.top, 12)
          }

          Spacer().frame(height: 30)
        }
        .background(
          ZStack {
            EwonicTheme.bgGradient
            wallpaperImage?                         // shows as soon as ready
              .resizable()
              .scaledToFill()
              .opacity(0.25)
          }
          .ignoresSafeArea()
        )
        .foregroundColor(.white)
        .task { await loadWallpaper() }             // asynchronous decode
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut, value: done)
      }
    }
  }

  // MARK: – Helpers
  private func loadWallpaper() async {
    await Task.detached(priority: .userInitiated) {
      if let ui = UIImage(named: "OnboardingBG") {   // off the main thread
        let img = Image(uiImage: ui)
        await MainActor.run {
          self.wallpaperImage = img
          self.isLoadingImage = false
        }
      } else {
        await MainActor.run { self.isLoadingImage = false }
      }
    }.value
  }
}
