//
//  ContentView.swift
//  eWonicApp
//
//  Polished UI shell for the real-time translation demo.
//  🔄 2025-06-23 – Hear picker removed; each device always hears its own speak language
//

import SwiftUI

struct ContentView: View {
  @StateObject private var vm = TranslationViewModel()

  var body: some View {
    NavigationView {
      ZStack {
        EwonicTheme.bgGradient.ignoresSafeArea()

        VStack(spacing: 18) {
          HeaderBar()

          ConnectionPill(status: vm.connectionStatus,
                         peerCount: vm.multipeerSession.connectedPeers.count)
            .padding(.horizontal)

          // ───── Permissions + Lobby logic
          if !vm.hasAllPermissions {
            PermissionCard(message: vm.permissionStatusMessage) {
              vm.checkAllPermissions()
            }
            .padding()

          } else if vm.multipeerSession.connectionState == .connected {
            // ───── Speak picker
            SpeakBar(
              speakLang: binding(\.speak_language),
              languages: vm.availableLanguages,
              disabled:  vm.isProcessing || vm.sttService.isListening
            )
            .padding(.horizontal)

            // ───── Conversation bubbles
            ConversationScroll(myText: vm.liveTranscript,
                               lastIn: vm.lastIncomingTranslated)

            // ───── Mic control
            RecordControl(
              isListening: vm.sttService.isListening,
              isProcessing: vm.isProcessing,
              start: vm.startMicrophone,
              stop:  vm.stopMicrophone
            )

          } else {
            PeerDiscoveryView(session: vm.multipeerSession)
          }

          Spacer(minLength: 0)
        }
        .padding(.bottom)
        .onDisappear {
          vm.multipeerSession.disconnect()
          vm.sttService.stopTranscribing()
        }

        ErrorBanner(message: $vm.errorMessage)
      }
      .navigationBarHidden(true)
      .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
        Button("OK") { vm.errorMessage = nil }
      } message: {
        Text(vm.errorMessage ?? "Unknown error")
      }
    }
    .accentColor(EwonicTheme.accent)
    .animation(.easeInOut, value: vm.multipeerSession.connectionState)
    .animation(.easeInOut, value: vm.hasAllPermissions)
  }

  private func binding<T>(_ path: ReferenceWritableKeyPath<TranslationViewModel, T>) -> Binding<T> {
    Binding(get: { vm[keyPath: path] },
            set: { vm[keyPath: path] = $0 })
  }
}

// ───────────────────────────────────────── Components ─────────────────────────────────────────

private struct HeaderBar: View {
  var body: some View {
    HStack {
      Image(systemName: "globe").font(.title2)
      Text("eWonic").font(.system(size: 28, weight: .bold))
      Spacer()
    }
    .foregroundColor(.white)
    .padding(.top, 8)
  }
}

private struct ConnectionPill: View {
  let status: String
  let peerCount: Int
  private var colour: Color {
    if status.contains("Lobby") { return .green }
    if status.contains("Connecting") { return .yellow }
    return .orange
  }
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(colour).frame(width: 8, height: 8)
      Text(status).font(.caption.weight(.medium))
      if peerCount > 0 {
        Text("· \(peerCount + 1)/\(MultipeerSession.peerLimit)")
          .font(.caption2)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .background(colour.opacity(0.2))
    .clipShape(Capsule())
    .foregroundColor(.white)
  }
}

private struct PermissionCard: View {
  let message: String; let request: () -> Void
  var body: some View {
    VStack(spacing: 12) {
      Text(message)
        .multilineTextAlignment(.center)
        .font(.callout.weight(.medium))
      Button("Grant Permissions", action: request)
        .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 14))
  }
}

// ────────────────────────── Speak picker ──────────────────────────

private struct SpeakBar: View {
  @Binding var speakLang: String
  let languages: [TranslationViewModel.Language]
  let disabled:  Bool
  var body: some View {
    LangMenu(label: "I Speak", code: $speakLang, languages: languages)
      .disabled(disabled)
      .opacity(disabled ? 0.55 : 1)
  }
}

private struct LangMenu: View {
  let label: String
  @Binding var code: String
  let languages: [TranslationViewModel.Language]
  var body: some View {
    Menu {
      ForEach(languages) { l in
        Button(l.name) { code = l.code }
      }
    } label: {
      HStack(spacing: 4) {
        Text(label + ":")
        Text(short(code))
          .fontWeight(.semibold)
        Image(systemName: "chevron.down")
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Color.white.opacity(0.12),
                  in: RoundedRectangle(cornerRadius: 8))
    }
    .foregroundColor(.white)
  }
  private func short(_ c: String) -> String {
    c.split(separator: "-").first?.uppercased() ?? c
  }
}

private struct ConversationScroll: View {
  let myText: String
  let lastIn: String
  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        Bubble(label: "You", text: myText,
               colour: .blue.opacity(0.13), align: .leading)
        Bubble(label: "Live", text: lastIn,
               colour: .purple.opacity(0.14), align: .trailing, loud: true)
      }
    }
    .frame(maxHeight: 330)
    .padding(.horizontal)
  }
}

private struct Bubble: View {
  let label: String; let text: String
  let colour: Color; let align: HorizontalAlignment
  var loud = false
  var body: some View {
    VStack(alignment: align, spacing: 3) {
      Text(label).font(.caption).foregroundColor(.white.opacity(0.7))
      Text(text.isEmpty ? "…" : text)
        .font(loud ? .title3 : .body)
        .padding(10)
        .background(colour,
                    in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity,
               alignment: align == .leading ? .leading : .trailing)
        .foregroundColor(.white)
    }
  }
}

private struct RecordControl: View {
  let isListening: Bool
  let isProcessing: Bool
  let start: () -> Void
  let stop:  () -> Void
  var body: some View {
    Button { isListening ? stop() : start() } label: {
      HStack {
        if isListening {
          ProgressView()
            .progressViewStyle(.circular)
          Text("Stop")
        } else if isProcessing {
          ProgressView()
            .progressViewStyle(.circular)
          Text("Processing…")
        } else {
          Image(systemName: "mic.fill")
          Text("Start")
        }
      }
      .frame(maxWidth: .infinity)
      .padding()
      .background(isListening ? Color.red
                 : (isProcessing ? Color.orange : EwonicTheme.accent),
                  in: RoundedRectangle(cornerRadius: 14))
      .foregroundColor(.white)
      .font(.headline)
    }
    .disabled(isProcessing && !isListening)
    .padding(.horizontal)
  }
}
// ────────────────────────── LOBBY DISCOVERY ──────────────────────────

private struct PeerDiscoveryView: View {
  @ObservedObject var session: MultipeerSession

  var body: some View {
    VStack(spacing: 18) {
      Text("Create or Join a Lobby")
        .font(.title2.weight(.semibold))

      HStack(spacing: 20) {
        Button {
          session.stopBrowsing()
          session.startHosting()
        } label: {
          Label("Host Lobby", systemImage: "antenna.radiowaves.left.and.right")
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(EwonicTheme.accent.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10))

        Button {
          session.stopHosting()
          session.startBrowsing()
        } label: {
          Label("Join Lobby", systemImage: "magnifyingglass")
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(Color.cyan.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10))
      }
      .buttonStyle(.plain)

      if !session.discoveredPeers.isEmpty {
        Text("Available Hosts:")
          .font(.headline)

        // 🔑 Fix: hide UITableView background + clear each row
        List(session.discoveredPeers, id: \.self) { peer in
          Button(peer.displayName) { session.invitePeer(peer) }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 220)

      } else if session.isBrowsing || session.isAdvertising {
        HStack {
          ProgressView()
          Text(session.isBrowsing ? "Searching…" : "Waiting…")
        }
        .foregroundColor(.white.opacity(0.7))
      }

      if session.connectionState != .notConnected ||
         session.isBrowsing || session.isAdvertising {
        Button("Stop Activities") { session.disconnect() }
          .padding(.top, 8)
          .buttonStyle(.bordered)
          .tint(.red)
      }
    }
    .padding()
    .background(Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 14))
    .foregroundColor(.white)
  }
}

// ────────────────────────── ERROR BANNER ──────────────────────────

private struct ErrorBanner: View {
  @Binding var message: String?
  var body: some View {
    if let msg = message {
      VStack {
        Spacer()
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.white)
          Text(msg)
            .font(.subheadline)
            .foregroundColor(.white)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 4)
          Button(action: { withAnimation { message = nil } }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.white)
          }
        }
        .padding()
        .background(Color.red.opacity(0.95),
                    in: RoundedRectangle(cornerRadius: 14))
        .padding()
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}

// ────────────────────────── PREVIEW ──────────────────────────

struct ContentView_Previews: PreviewProvider {
  static var previews: some View {
    ContentView().environment(\.colorScheme, .dark)
  }
}

