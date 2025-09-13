//
//  ContentView.swift
//  eWonicApp
//
//  One Phone screen added 2025-08-11.
//

import SwiftUI

struct ContentView: View {
  @StateObject private var view_model = TranslationViewModel()

  var body: some View {
    NavigationView {
      ZStack {
        EwonicTheme.bgGradient.ignoresSafeArea()

        VStack(spacing: 16) {
          Header_bar()

          ModePicker(mode: $view_model.mode)

          Connection_pill(status: view_model.connectionStatus,
                          peer_count: view_model.multipeerSession.connectedPeers.count)

          if !view_model.hasAllPermissions {
            Permission_card(msg: view_model.permissionStatusMessage) {
              view_model.checkAllPermissions()
            }

          } else if view_model.mode == .peer &&
                    view_model.multipeerSession.connectionState != .connected {

            PeerDiscoveryView(session: view_model.multipeerSession)

          } else if view_model.mode == .peer {

            // ───── Peer (unchanged main UI) ─────
            Language_bar(my_lang:   $view_model.myLanguage,
                         peer_lang: $view_model.peerLanguage,
                         list:      view_model.availableLanguages,
                         disabled:  view_model.isProcessing || view_model.sttService.isListening)

            Voice_bar(voice_for_lang: $view_model.voice_for_lang,
                      voices:        view_model.availableVoices)

            Conversation_scroll(my_text:  view_model.myTranscribedText,
                                peer_text: view_model.peerSaidText,
                                translated: view_model.translatedTextForMeToHear)

            Settings_sliders(mic: $view_model.micSensitivity,
                             speed: $view_model.playbackSpeed)

            Record_button(is_listening:  view_model.sttService.isListening,
                          is_processing: view_model.isProcessing,
                          start_action:  view_model.startListening,
                          stop_action:   view_model.stopListening)

            Button("Clear History") { view_model.resetConversationHistory() }
              .font(.caption)
              .foregroundColor(.white.opacity(0.7))
              .padding(.top, 4)

          } else {
            // ───── One‑Phone Conversation ─────
            OnePhoneConversationScreen(vm: view_model)
          }

          Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .onDisappear {
          view_model.multipeerSession.disconnect()
          view_model.stopListening()
        }

        ErrorBanner(message: $view_model.errorMessage)
      }
      .navigationBarHidden(true)
    }
    .accentColor(EwonicTheme.accent)
  }
}

// ────────────────────────── Common header/pill/pickers ──────────────────────────

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

private struct ModePicker: View {
  @Binding var mode: TranslationViewModel.Mode
  var body: some View {
    Picker("Mode", selection: $mode) {
      Text("Peer").tag(TranslationViewModel.Mode.peer)
      Text("One Phone").tag(TranslationViewModel.Mode.onePhone)
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 2)
  }
}

private struct Connection_pill: View {
  let status: String
  let peer_count: Int
  private var colour: Color {
    if status.contains("Connected") || status.contains("One Phone") { return EwonicTheme.pillConnected }
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

// ────────────────────────── PEER COMPONENTS (restored) ──────────────────────────

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
              voice_for_lang = voice_for_lang
            } label: {
              if picked {
                Label(v.name, systemImage: "checkmark")
                  .font(.body.weight(.semibold))
              } else {
                Text(v.name).font(.body)
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

private struct Settings_sliders: View {
  @Binding var mic: Double
  @Binding var speed: Double
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading) {
        Text("Mic Sensitivity")
          .font(.caption)
          .foregroundColor(.white.opacity(0.7))
        Slider(value: $mic, in: 0...1)
          .tint(EwonicTheme.accent)
      }
      VStack(alignment: .leading) {
        Text("Playback Speed")
          .font(.caption)
          .foregroundColor(.white.opacity(0.7))
        Slider(value: $speed, in: 0...1)
          .tint(EwonicTheme.accent)
      }
    }
  }
}

private struct VoicePickerForLang: View {
  let title: String              // e.g. "English (US)"
  let lang: String               // e.g. "en-US"
  @Binding var voice_for_lang: [String:String]
  let voices: [TranslationViewModel.Voice]

  var body: some View {
    let base = String(lang.prefix(2)).lowercased()
    let filtered = voices.filter { $0.language.lowercased().hasPrefix(base + "-") || $0.language == lang }
                         .sorted { $0.name < $1.name }

    let currentId = voice_for_lang[lang]
    let currentName = filtered.first(where: { $0.identifier == currentId })?.name ?? "System"

    Menu {
      Section(header: Text(title)) {
        Button("System default") {
          voice_for_lang.removeValue(forKey: lang)
          voice_for_lang = voice_for_lang
        } 
        ForEach(filtered) { v in
          let picked = (currentId == v.identifier)
        Button {
          voice_for_lang[lang] = v.identifier
          voice_for_lang = voice_for_lang
        } label: {
          HStack {
            if picked { Image(systemName: "checkmark") }
            Text(v.name)
          }
          .font(picked ? .body.weight(.semibold) : .body)
        }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "speaker.wave.2.fill")
        Text(short(lang))          // “EN”, “ES”, etc.
          .fontWeight(.semibold)
        Text(currentName)          // shows the chosen voice
          .lineLimit(1)
          .truncationMode(.tail)
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

private struct PeerDiscoveryView: View {
  @ObservedObject var session: MultipeerSession

  var body: some View {
    VStack(spacing: 18) {
      Text("Connect to a Peer")
        .font(.title2.weight(.semibold))

      HStack(spacing: 20) {
        Button {
          session.stopBrowsing()
          session.startHosting()
        } label: {
          Label("Host", systemImage: "antenna.radiowaves.left.and.right")
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(EwonicTheme.accent.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10))

        Button {
          session.stopHosting()
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



// ────────────────────────── ONE‑PHONE SCREEN ──────────────────────────

private struct OnePhoneConversationScreen: View {
  @ObservedObject var vm: TranslationViewModel

  var body: some View {
    VStack(spacing: 14) {
      // Title line like Google’s “Conversation”
      HStack {
        Text("Conversation")
          .font(.title2.weight(.semibold))
        Spacer()
        Menu {
          // keep future options here
          Button("Clear History") { vm.localTurns.removeAll() }
        } label: {
          Image(systemName: "ellipsis.circle").font(.title3)
        }
      }
      .foregroundColor(.white.opacity(0.95))
        
        HStack(spacing: 10) {
          VoicePickerForLang(
            title: labelFor(vm.myLanguage),
            lang:  vm.myLanguage,
            voice_for_lang: $vm.voice_for_lang,
            voices: vm.availableVoices
          )
          VoicePickerForLang(
            title: labelFor(vm.peerLanguage),
            lang:  vm.peerLanguage,
            voice_for_lang: $vm.voice_for_lang,
            voices: vm.availableVoices
          )
        }

      // Running conversation
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 12) {
            ForEach(vm.localTurns) { turn in
              TurnCard(turn: turn) {
                vm.ttsService.speak(
                  text: turn.translatedText,
                  languageCode: turn.targetLang,
                  voiceIdentifier: vm.voice_for_lang[turn.targetLang]
                )
              }
            }

            if !vm.translatedTextForMeToHear.isEmpty {
              // live line
              LiveCard(text: vm.translatedTextForMeToHear)
            }
          }
          .onChange(of: vm.localTurns.count) { _ in
            if let last = vm.localTurns.last?.id {
              withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
          }
        }
        .frame(maxHeight: 360)
      }

      // Language tiles + mic
      VStack(spacing: 10) {
        LanguageTile(
          title: labelFor(vm.myLanguage),
          code:  vm.myLanguage,
          languages: vm.availableLanguages,
          placeholder: vm.isAutoListening ? listeningLabel(for: vm.myLanguage) : "Enter text",
          text: $vm.leftDraft,
          onLanguageChanged: { vm.myLanguage = $0 },
          onSend: vm.submitLeftDraft
        )

        LanguageTile(
          title: labelFor(vm.peerLanguage),
          code:  vm.peerLanguage,
          languages: vm.availableLanguages,
          placeholder: vm.isAutoListening ? listeningLabel(for: vm.peerLanguage) : "Enter text",
          text: $vm.rightDraft,
          onLanguageChanged: { vm.peerLanguage = $0 },
          onSend: vm.submitRightDraft
        )

        HStack {
          Spacer()
          MicButton(
            isListening: vm.isAutoListening,
            start:  vm.startAuto,
            stop:   vm.stopAuto
          )
          Spacer()
        }.padding(.top, 6)
      }
    }
  }

  private func labelFor(_ code: String) -> String {
    vm.availableLanguages.first(where: { $0.code == code })?.name
      ?? code
  }

  private func listeningLabel(for code: String) -> String {
    switch String(code.prefix(2)).lowercased() {
    case "es": return "Escuchando…"
    case "fr": return "À l’écoute…"
    case "de": return "Zuhören…"
    case "ja": return "リスニング中…"
    case "zh": return "正在聆听…"
    default:   return "Listening…"
    }
  }
}

private struct TurnCard: View {
  let turn: TranslationViewModel.LocalTurn
  var onReplay: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(turn.sourceText)
        .font(.headline)
        .foregroundColor(.primary)
        .padding(.bottom, 2)

      HStack(alignment: .center) {
        Text(turn.translatedText)
          .font(.title3.weight(.semibold))
          .foregroundColor(EwonicTheme.accent)
        Spacer(minLength: 8)
        Button(action: onReplay) {
          Image(systemName: "play.circle.fill").font(.title2)
        }
        .buttonStyle(.plain)
        .foregroundColor(EwonicTheme.accent)
      }
    }
    .padding(14)
    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
    .id(turn.id)
  }
}

private struct LiveCard: View {
  let text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Live").font(.caption).foregroundColor(.secondary)
      Text(text).font(.headline)
        .foregroundColor(.white)
    }
    .padding(12)
    .background(EwonicTheme.bubbleTranslated, in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct LanguageTile: View {
  let title: String
  let code: String
  let languages: [TranslationViewModel.Language]
  let placeholder: String

  @Binding var text: String
  let onLanguageChanged: (String) -> Void
  let onSend: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Menu {
        ForEach(languages) { l in
          Button(l.name) { onLanguageChanged(l.code) }
        }
      } label: {
        HStack(spacing: 6) {
          Text(title).font(.subheadline.weight(.semibold))
          Image(systemName: "chevron.down").font(.caption)
        }
        .foregroundColor(.black.opacity(0.8))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 8))
      }

      HStack {
        TextField(placeholder, text: $text)
          .textFieldStyle(.plain)
          .disableAutocorrection(true)
          .autocapitalization(.none)
        Button(action: onSend) {
          Image(systemName: "arrow.up.circle.fill").font(.title2)
        }
        .buttonStyle(.plain)
      }
      .padding(12)
      .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
      .foregroundColor(.white)
    }
  }
}

private struct MicButton: View {
  let isListening: Bool
  let start: () -> Void
  let stop:  () -> Void
  var body: some View {
    Button { isListening ? stop() : start() } label: {
      Image(systemName: isListening ? "stop.fill" : "mic.fill")
        .font(.title)
        .padding(26)
        .background(isListening ? Color.red : EwonicTheme.accent,
                    in: Circle())
        .foregroundColor(.white)
    }
  }
}
