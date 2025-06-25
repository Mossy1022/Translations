//
//  ContentView.swift
//  eWonicApp
//
//  Polished UI shell for the real-time translation demo.
//  Voice picker added 2025-06-10.
//

import SwiftUI

struct ContentView: View {
  @StateObject private var view_model = TranslationViewModel()

  var body: some View {
    NavigationView {
      ZStack {
        EwonicTheme.bgGradient.ignoresSafeArea()

        VStack(spacing: 20) {
          Header_bar()

          Connection_pill(status: view_model.connectionStatus,
                          peer_count: view_model.multipeerSession.connectedPeers.count)

          if !view_model.hasAllPermissions {
            Permission_card(msg: view_model.permissionStatusMessage) {
              view_model.checkAllPermissions()
            }

          } else if view_model.multipeerSession.connectionState == .connected {

            Language_bar(my_lang:   $view_model.myLanguage,
                         peer_lang: $view_model.peerLanguage,
                         list:      view_model.availableLanguages,
                         disabled:  view_model.isProcessing || view_model.sttService.isListening)

              Voice_bar(voice_for_lang: $view_model.voice_for_lang,
                        voices:        view_model.availableVoices)

            Conversation_scroll(my_text:  view_model.myTranscribedText,
                                peer_text: view_model.peerSaidText,
                                translated: view_model.translatedTextForMeToHear)

            Record_button(is_listening:  view_model.sttService.isListening,
                          is_processing: view_model.isProcessing,
                          start_action:  view_model.startListening,
                          stop_action:   view_model.stopListening)

            Button("Clear History") { view_model.resetConversationHistory() }
              .font(.caption)
              .foregroundColor(.white.opacity(0.7))
              .padding(.top, 4)

          } else {
            PeerDiscoveryView(session: view_model.multipeerSession)
          }

          Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .onDisappear {
          view_model.multipeerSession.disconnect()
          view_model.sttService.stopTranscribing()
        }

        ErrorBanner(message: $view_model.errorMessage)
      }
      .navigationBarHidden(true)
    }
    .accentColor(EwonicTheme.accent)
  }
}

// ────────────────────────── COMPONENTS ──────────────────────────

private struct Header_bar: View {
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

private struct Connection_pill: View {
  let status: String
  let peer_count: Int
  private var colour: Color {
    if status.contains("Connected") { return EwonicTheme.pillConnected }
    if status.contains("Connecting") { return EwonicTheme.pillConnecting }
    return EwonicTheme.pillDisconnected
  }
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(colour).frame(width: 8, height: 8)
      Text(status).font(.caption.weight(.medium))
      if peer_count > 0 { Text("· \(peer_count)").font(.caption2) }
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .background(colour.opacity(0.15))
    .clipShape(Capsule())
    .foregroundColor(.white)
  }
}

private struct Permission_card: View {
  let msg: String; let req: () -> Void
  var body: some View {
    VStack(spacing: 12) {
      Text(msg).multilineTextAlignment(.center)
        .font(.callout.weight(.medium))
      Button("Grant Permissions", action: req)
        .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 14))
  }
}

private struct Language_bar: View {
  @Binding var my_lang: String
  @Binding var peer_lang: String
  let list: [TranslationViewModel.Language]
  let disabled: Bool
  var body: some View {
    HStack(spacing: 12) {
      Lang_menu(label: "I Speak", code: $my_lang, list: list)
      Image(systemName: "arrow.left.arrow.right")
        .foregroundColor(.white.opacity(disabled ? 0.35 : 1))
      Lang_menu(label: "Peer Hears", code: $peer_lang, list: list)
    }
    .disabled(disabled)
    .opacity(disabled ? 0.55 : 1)
  }
}

private struct Lang_menu: View {
  let label: String
  @Binding var code: String
  let list: [TranslationViewModel.Language]
  var body: some View {
    Menu {
      ForEach(list) { l in Button(l.name) { code = l.code } }
    } label: {
      HStack(spacing: 4) {
        Text(label + ":")
        Text(short(code)).fontWeight(.semibold)
        Image(systemName: "chevron.down")
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Color.white.opacity(0.12),
                  in: RoundedRectangle(cornerRadius: 8))
    }
    .foregroundColor(.white)
  }
  private func short(_ c: String) -> String { c.split(separator: "-").first?.uppercased() ?? c }
}

// ────────────────────────── Voice picker  ──────────────────────────
private struct Voice_bar: View {
  @Binding var voice_for_lang: [String:String]
  let voices: [TranslationViewModel.Voice]

  var body: some View {
    Menu {
      ForEach(grouped(), id:\.key) { lang, list in
        Section(header: Text(lang).font(.footnote)) {
          ForEach(list) { v in
            let picked = voice_for_lang[lang] == v.identifier
            Button(role: .none) {
              voice_for_lang[lang] = v.identifier
              voice_for_lang = voice_for_lang            // force Combine publish
            } label: {
              if picked {
                Label(v.name, systemImage: "checkmark")
                  .font(.body.weight(.semibold))
              } else {
                Text(v.name)
                  .font(.body)
              }
            }
          }
        }
      }

      if !voice_for_lang.isEmpty {
        Divider()
        Button("System defaults") {
          voice_for_lang.removeAll()
          voice_for_lang = [:]
        }
      }
    } label: {
      HStack(spacing:4){
        Image(systemName:"speaker.wave.2.fill")
        Text("Voices").fontWeight(.semibold)
        Image(systemName:"chevron.down")
      }
      .padding(.horizontal,10).padding(.vertical,6)
      .background(Color.white.opacity(0.12),
                  in: RoundedRectangle(cornerRadius:8))
    }
    .foregroundColor(.white)
  }

  private func grouped()
    -> [(key:String, value:[TranslationViewModel.Voice])] {
      Dictionary(grouping: voices, by: { $0.language })
        .sorted { $0.key < $1.key }
  }
}

// ────────────────────────── Conversation  ──────────────────────────

private struct Conversation_scroll: View {
  let my_text: String
  let peer_text: String
  let translated: String
  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        Bubble(label: "You",  text: my_text,
               colour: EwonicTheme.bubbleSent, align: .leading)
        Bubble(label: "Peer", text: peer_text,
               colour: EwonicTheme.bubbleReceived, align: .trailing)
        Bubble(label: "Live", text: translated,
               colour: EwonicTheme.bubbleTranslated, align: .trailing, loud: true)
      }
    }
    .frame(maxHeight: 330)
  }
}

private struct Bubble: View {
  let label: String; let text: String
  let colour: Color; let align: HorizontalAlignment
  var loud: Bool = false
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

private struct Record_button: View {
  let is_listening: Bool
  let is_processing: Bool
  let start_action: () -> Void
  let stop_action: () -> Void
  var body: some View {
    Button { is_listening ? stop_action() : start_action() } label: {
      HStack {
        if is_processing { ProgressView().progressViewStyle(.circular) }
        Image(systemName: is_listening ? "stop.fill" : "mic.fill")
        Text(is_listening ? "Stop" : (is_processing ? "Processing…" : "Start"))
      }
      .frame(maxWidth: .infinity)
      .padding()
      .background(is_listening ? Color.red :
                    (is_processing ? Color.orange : EwonicTheme.accent),
                  in: RoundedRectangle(cornerRadius: 14))
      .foregroundColor(.white)
      .font(.headline)
    }
    .disabled(is_processing && !is_listening)
  }
}

// ────────────────────────── PEER DISCOVERY (unchanged) ──────────────────────────
// … (rest of PeerDiscoveryView stays exactly the same) …


// ────────────────────────── PEER DISCOVERY ──────────────────────────

private struct PeerDiscoveryView: View {
  @ObservedObject var session: MultipeerSession

  var body: some View {
    VStack(spacing: 18) {
      Text("Connect to a Peer")
        .font(.title2.weight(.semibold))

      HStack(spacing: 20) {
        Button {
          session.stopActivities()
          session.startHosting()
        } label: {
          Label("Host", systemImage: "antenna.radiowaves.left.and.right")
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(EwonicTheme.accent.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10))

        Button {
          session.stopActivities()
          session.startBrowsing()
        } label: {
          Label("Join", systemImage: "magnifyingglass")
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(Color.cyan.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10))
      }
      .buttonStyle(.plain)

      if !session.discoveredPeers.isEmpty {
        Text("Found Peers:")
          .font(.headline)

        // 🔑 Fix: hide UITableView background + clear each row
        List(session.discoveredPeers, id: \.self) { peer in
          Button(peer.displayName) { session.invitePeer(peer) }
            .listRowBackground(Color.clear)        // row bg = transparent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)          // table bg = transparent
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
        .background(Color.red.opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
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
