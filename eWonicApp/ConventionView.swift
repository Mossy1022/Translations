import SwiftUI

struct ConventionView: View {
  @StateObject private var view_model = ConventionViewModel()

  var body: some View {
    NavigationView {
      ZStack {
        EwonicTheme.bgGradient.ignoresSafeArea()
        VStack(spacing: 20) {
          Header_bar()

          Language_bar(my_lang: $view_model.myLanguage,
                       list: view_model.availableLanguages,
                       disabled: view_model.isProcessing || view_model.sttService.isListening)

          Lang_menu(label: "Speaker", code: $view_model.incomingLanguage, list: view_model.availableLanguages)
            .disabled(view_model.isProcessing || view_model.sttService.isListening)
            .opacity(view_model.isProcessing || view_model.sttService.isListening ? 0.55 : 1)

          Voice_bar(voice_for_lang: $view_model.voice_for_lang,
                    voices: view_model.availableVoices)

          ConventionConversation(speaker: view_model.speakerTranscribedText,
                                 translated: view_model.translatedTextForMeToHear)

          Settings_sliders(mic: $view_model.micSensitivity,
                             speed: $view_model.playbackSpeed)

          Record_button(is_listening: view_model.sttService.isListening,
                        is_processing: view_model.isProcessing,
                        start_action: view_model.startListening,
                        stop_action: view_model.stopListening)

          Button("Clear History") { view_model.resetConversationHistory() }
            .font(.caption)
            .foregroundColor(.white.opacity(0.7))
            .padding(.top, 4)

          Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .onDisappear { view_model.sttService.stop() }

        ErrorBanner(message: $view_model.errorMessage)
      }
      .navigationBarHidden(true)
    }
    .accentColor(EwonicTheme.accent)
  }
}

// MARK: - Components copied from ContentView

struct Header_bar: View {
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

struct Language_bar: View {
  @Binding var my_lang: String
  let list: [ConventionViewModel.Language]
  let disabled: Bool
  var body: some View {
    Lang_menu(label: "I Speak", code: $my_lang, list: list)
      .disabled(disabled)
      .opacity(disabled ? 0.55 : 1)
  }
}

struct Lang_menu: View {
  let label: String
  @Binding var code: String
  let list: [ConventionViewModel.Language]
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
      .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
    .foregroundColor(.white)
  }
  private func short(_ c: String) -> String { c.split(separator: "-").first?.uppercased() ?? c }
}

struct Voice_bar: View {
  @Binding var voice_for_lang: [String:String]
  let voices: [ConventionViewModel.Voice]

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
                Label(v.name, systemImage: "checkmark").font(.body.weight(.semibold))
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
          voice_for_lang.removeAll(); voice_for_lang = [:]
        }
      }
    } label: {
      HStack(spacing:4){
        Image(systemName:"speaker.wave.2.fill")
        Text("Voices").fontWeight(.semibold)
        Image(systemName:"chevron.down")
      }
      .padding(.horizontal,10).padding(.vertical,6)
      .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius:8))
    }
    .foregroundColor(.white)
  }

  private func grouped() -> [(key: String, value: [ConventionViewModel.Voice])] {
    Dictionary(grouping: voices, by: { short($0.language) }).sorted { $0.key < $1.key }
  }
  private func short(_ c: String) -> String { c.split(separator: "-").first?.uppercased() ?? c }
}

struct ConventionConversation: View {
  let speaker: String
  let translated: String
  var body: some View {
    ScrollView {
      VStack(spacing:14){
        Bubble(label:"Speaker", text:speaker,
               colour:EwonicTheme.bubbleReceived, align:.leading)
        Bubble(label:"Live", text:translated,
               colour:EwonicTheme.bubbleTranslated, align:.trailing, loud:true)
      }
    }
    .frame(maxHeight:330)
  }
}

struct Bubble: View {
  let label: String; let text: String
  let colour: Color; let align: HorizontalAlignment
  var loud: Bool = false
  var body: some View {
    VStack(alignment: align, spacing: 3) {
      Text(label).font(.caption).foregroundColor(.white.opacity(0.7))
      Text(text.isEmpty ? "…" : text)
        .font(loud ? .title3 : .body)
        .padding(10)
        .background(colour, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity,
               alignment: align == .leading ? .leading : .trailing)
        .foregroundColor(.white)
    }
  }
}

struct Settings_sliders: View {
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

struct Record_button: View {
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

struct ErrorBanner: View {
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

