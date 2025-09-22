import SwiftUI

@MainActor
struct OnboardingView: View {
  @AppStorage(LanguageSettings.Keys.selectedLanguage)
  private var storedLanguageCode: String?
  @AppStorage(LanguageSettings.Keys.didCompleteWelcome)
  private var didCompleteWelcome     = false

  @State private var showMainShell   = false
  @State private var selectedLanguage: AppLanguage = LanguageSettings.currentLanguage
  @State private var wallpaperImage  : Image?
  @State private var isLoadingImage  = true

  var body: some View {
    let locale = Locale(identifier: LanguageSettings.currentLanguage.localeIdentifier)
    return Group {
      if showMainShell || shouldSkipAll {
        MainShell()
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      } else {
        onboardingContent
      }
    }
    .environment(\.locale, locale)
    .animation(.easeInOut, value: showMainShell)
    .onAppear {
      if shouldSkipAll { showMainShell = true }
    }
    .onChange(of: storedLanguageCode) { newValue in
      if let newValue, let lang = AppLanguage(rawValue: newValue) {
        selectedLanguage = lang
      }
      if shouldSkipAll { showMainShell = true }
    }
  }

  // MARK: – Helpers

  private var hasStoredLanguage: Bool {
    storedLanguageCode != nil
  }

  private var shouldSkipAll: Bool {
    hasStoredLanguage && didCompleteWelcome
  }

    @ViewBuilder
    private var onboardingContent: some View {
      ZStack {
        EwonicTheme.bgGradient
        wallpaperImage?
          .resizable()
          .scaledToFill()
          .opacity(0.25)
      }
      .ignoresSafeArea()
      .overlay {
        // ⬇️ wrap all overlay content in a padded container
        VStack {
          Group {
            if hasStoredLanguage {
              welcomeView
            } else {
              LanguageSetupView(selection: $selectedLanguage,
                                continueAction: commitLanguageSelection)
            }
          }
          .foregroundColor(.white)
        }
        .padding(.horizontal, 24)              // ← adds safe side gutter
        .frame(maxWidth: .infinity, alignment: .center)
      }
      .task { await loadWallpaper() }
    }

  private var welcomeView: some View {
    VStack(spacing: 40) {
      Spacer()

      Image(systemName: "globe")
        .font(.system(size: 80, weight: .light))
        .foregroundStyle(EwonicTheme.accent)

        Text("Break language barriers instantly.".localized)
          .multilineTextAlignment(.center)
          .font(.largeTitle.weight(.semibold))
          .lineLimit(2)
          .minimumScaleFactor(0.8)
          .padding(.horizontal, 30)
          .frame(maxWidth: 680)                 // cap width for readability
        .frame(maxWidth: .infinity, alignment: .center)  // then center the view
        
      VStack(alignment: .leading, spacing: 18) {
        Label("Hands-free, real-time speech".localized,       systemImage: "waveform")
        Label("Auto-discovers nearby users".localized,        systemImage: "antenna.radiowaves.left.and.right")
        Label("No special hardware required".localized,       systemImage: "headphones")
      }
      .frame(maxWidth: 680)                               // 1) readable width
      .frame(maxWidth: .infinity, alignment: .center)     // 2) center the block
      .padding(.horizontal, 40)
      .labelStyle(.titleAndIcon)
      .foregroundColor(.white.opacity(0.9))

      Spacer()

      Button("Start".localized) { startMainApplication() }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding()
        .background(EwonicTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 40)
        .disabled(isLoadingImage)

      if isLoadingImage {
        ProgressView().progressViewStyle(.circular)
          .tint(.white.opacity(0.7))
          .padding(.top, 12)
      }

      Spacer().frame(height: 30)
    }
    .padding(.horizontal, 6)
  }

  private func commitLanguageSelection() {
    storedLanguageCode = selectedLanguage.rawValue
    LanguageSettings.updateLanguage(selectedLanguage)
    didCompleteWelcome = false
  }

  private func startMainApplication() {
    didCompleteWelcome = true
    withAnimation { showMainShell = true }
  }

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

private struct LanguageSetupView: View {
  @Binding var selection: AppLanguage
  let continueAction: () -> Void

  @State private var currentMessageIndex = 0
  @State private var tickerTask: Task<Void, Never>? = nil

  private let languages = AppLanguage.allCases

  var body: some View {
    VStack(spacing: 36) {
      // keep content clear of the notch/Dynamic Island
      Spacer(minLength: 24)

      // ── Rotating headline (fixed height via ZStack) ─────────────────
      VStack(spacing: 10) {
        ZStack {
          ForEach(languages.indices, id: \.self) { i in
            Text(languages[i].welcomeMessage)
              .font(.title2.weight(.semibold))
              .multilineTextAlignment(.center)
              .lineLimit(3)
              .minimumScaleFactor(0.85)
              .padding(.horizontal, 24)
              .opacity(i == currentMessageIndex ? 1 : 0)
              .animation(.easeInOut(duration: 0.25), value: currentMessageIndex)
          }
        }

        ZStack {
          ForEach(languages.indices, id: \.self) { i in
            Text(languages[i].nativeName)
              .font(.headline)
              .foregroundColor(.white.opacity(0.75))
              .lineLimit(1)
              .minimumScaleFactor(0.9)
              .opacity(i == currentMessageIndex ? 1 : 0)
              .animation(.easeInOut(duration: 0.25), value: currentMessageIndex)
          }
        }
      }
      .frame(maxWidth: 600) // nicer on big phones/iPad

      // ── Selector + helper text (stable layout) ───────────────────────
      VStack(alignment: .leading, spacing: 18) {
        Text("Select your language".localized)
          .font(.headline)

        Menu {
          ForEach(languages) { lang in
            Button(lang.nativeName) { selection = lang }
          }
        } label: {
          HStack {
            Text(selection.nativeName)
              .font(.body.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.9)
            Spacer()
            Image(systemName: "chevron.down")
          }
          .padding(.vertical, 12)
          .padding(.horizontal, 16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.white.opacity(0.18),
                      in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundColor(.white)

        Text("We'll use this for translations and the app interface.".localized)
          .font(.footnote)
          .foregroundColor(.white.opacity(0.75))
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 32)
      .frame(maxWidth: 600)

      // ── Continue button (pinned visually) ────────────────────────────
      Button(action: continueAction) {
        Text("Continue".localized)
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding()
      }
      .background(EwonicTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .padding(.horizontal, 40)
      .frame(maxWidth: 640)

      Spacer(minLength: 30)
    }
    .padding(.vertical, 36)
    .padding(.horizontal, 20)
    .onAppear { startTicker() }
    .onDisappear { tickerTask?.cancel(); tickerTask = nil }
  }
    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task {
          while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            await MainActor.run {
              withAnimation(.easeInOut(duration: 0.6)) {
                currentMessageIndex = (currentMessageIndex + 1) % languages.count
              }
            }
          }
        }
      }
    }
