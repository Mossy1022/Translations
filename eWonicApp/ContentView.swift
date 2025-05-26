//
//  ContentView.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TranslationViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 15) {
                HeaderView()

                ConnectionPillView(status: viewModel.connectionStatus, peerCount: viewModel.multipeerSession.connectedPeers.count)
                    .padding(.horizontal)
                
                if !viewModel.hasAllPermissions {
                    PermissionRequestView(
                        message: viewModel.permissionStatusMessage,
                        onRequest: { viewModel.checkAllPermissions() }
                    )
                    .padding()
                } else {
                    if viewModel.multipeerSession.connectionState == .connected {
                        LanguageConfigView(
                            myLanguage: $viewModel.myLanguage,
                            peerLanguage: $viewModel.peerLanguage,
                            availableLanguages: viewModel.availableLanguages,
                            isDisabled: viewModel.isProcessing || viewModel.sttService.isListening
                        )
                        .padding(.horizontal)

                        ConversationView(
                            myTranscribedText: viewModel.myTranscribedText,
                            peerSaidText: viewModel.peerSaidText,
                            translatedTextForMeToHear: viewModel.translatedTextForMeToHear
                        )

                        RecordControlView(
                            isListening: viewModel.sttService.isListening,
                            isProcessing: viewModel.isProcessing, // General processing lock
                            startAction: viewModel.startListening,
                            stopAction: viewModel.stopListening
                        )
                        
                        Button("Clear History") {
                            viewModel.resetConversationHistory()
                        }
                        .font(.caption)
                        .padding(.top, 5)
                        
                    } else {
                        PeerDiscoveryView(session: viewModel.multipeerSession)
                    }
                }
                Spacer()
            }
            .navigationBarHidden(true)
            .onAppear {
                // viewModel.checkAllPermissions() // Already called in init
            }
            .onDisappear {
                viewModel.multipeerSession.disconnect() // Good practice
                viewModel.sttService.stopTranscribing() // Stop STT if view disappears
            }
            // Alert for errors (optional)
            // .alert("Error", isPresented: $viewModel.showError, presenting: viewModel.errorMessage) { _ in Button("OK") {} } message: { Text($0) }
        }
        .animation(.easeInOut, value: viewModel.multipeerSession.connectionState)
        .animation(.easeInOut, value: viewModel.hasAllPermissions)
    }
}

struct HeaderView: View {
    var body: some View {
        Text("Voice Translator")
            .font(.system(size: 28, weight: .bold))
            .padding(.top)
    }
}

struct ConnectionPillView: View {
    let status: String
    let peerCount: Int
    
    var color: Color {
        if status.contains("Connected") { return .green }
        if status.contains("Connecting") { return .yellow }
        return .orange
    }

    var body: some View {
        Text(status)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

struct PermissionRequestView: View {
    let message: String
    let onRequest: () -> Void

    var body: some View {
        VStack {
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.orange)
            Button("Check/Request Permissions") {
                onRequest()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 15)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption)
            .padding(.top, 5)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}


struct LanguageConfigView: View {
    @Binding var myLanguage: String
    @Binding var peerLanguage: String
    let availableLanguages: [TranslationViewModel.Language]
    let isDisabled: Bool

    var body: some View {
        HStack {
            PickerBox(label: "I Speak:", selection: $myLanguage, languages: availableLanguages)
            Spacer()
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.title2)
                .foregroundColor(isDisabled ? .gray : .accentColor)
            Spacer()
            PickerBox(label: "Peer Hears:", selection: $peerLanguage, languages: availableLanguages)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

struct PickerBox: View {
    let label: String
    @Binding var selection: String
    let languages: [TranslationViewModel.Language]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.gray)
            Picker(label, selection: $selection) {
                ForEach(languages) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .labelsHidden()
            .pickerStyle(MenuPickerStyle())
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct ConversationView: View {
    let myTranscribedText: String
    let peerSaidText: String
    let translatedTextForMeToHear: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextBubble(label: "You (Detected Speech):", text: myTranscribedText, alignment: .leading, color: .blue.opacity(0.1))
            TextBubble(label: "Peer Said (Original):", text: peerSaidText, alignment: .trailing, color: .green.opacity(0.1))
            TextBubble(label: "You Hear (Translated):", text: translatedTextForMeToHear, alignment: .trailing, color: .purple.opacity(0.1), isLoud: true)
        }
        .padding(.horizontal)
    }
}

struct TextBubble: View {
    let label: String
    let text: String
    let alignment: HorizontalAlignment
    let color: Color
    var isLoud: Bool = false

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Text(text.isEmpty ? "..." : text)
                .font(isLoud ? .title3 : .body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
                .background(color)
                .cornerRadius(12)
                .lineLimit(nil) // Allow multiple lines
                .fixedSize(horizontal: false, vertical: true) // Ensure it expands vertically
        }
    }
}

struct RecordControlView: View {
    let isListening: Bool
    let isProcessing: Bool
    let startAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        Button {
            if isListening {
                stopAction()
            } else {
                startAction()
            }
        } label: {
            HStack {
                if isListening {
                    ProgressView() // Shows when actually listening via STT
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Stop Listening")
                } else if isProcessing {
                     ProgressView() // Shows for other processing like translation/TTS
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Processing...")
                }
                else {
                    Image(systemName: "mic.fill")
                    Text("Start Listening")
                }
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(isListening ? Color.red : (isProcessing ? Color.orange : Color.green))
            .cornerRadius(10)
        }
        .disabled(isProcessing && !isListening) // Disable if generic processing but not actively STT listening
        .padding(.horizontal)
    }
}


struct PeerDiscoveryView: View {
  @ObservedObject var session: MultipeerSession   // 👈 watch the session itself

  var body: some View {
    VStack(spacing: 15) {
      Text("Connect to a Peer")
        .font(.title2.weight(.semibold))
        .padding(.bottom)

      HStack(spacing: 20) {
        Button {
          session.stopBrowsing()
          session.startHosting()
        } label: {
          Label("Host Session", systemImage: "antenna.radiowaves.left.and.right")
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.purple.opacity(0.2))
            .cornerRadius(10)
        }

        Button {
          session.stopHosting()
          session.startBrowsing()
        } label: {
          Label("Join Session", systemImage: "magnifyingglass")
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.cyan.opacity(0.2))
            .cornerRadius(10)
        }
      }
      .buttonStyle(.bordered)

      if !session.discoveredPeers.isEmpty {
        Text("Found Peers:")
          .font(.headline)
          .padding(.top)

        List(session.discoveredPeers, id: \.self) { peer in
          Button(peer.displayName) { session.invitePeer(peer) }
        }
        .listStyle(.plain)
        .frame(maxHeight: 200)
      } else if session.isBrowsing || session.isAdvertising {
        HStack {
          ProgressView()
          Text(session.isBrowsing
               ? "Searching for hosts..." : "Waiting for connections...")
        }
        .padding(.top)
        .foregroundColor(.gray)
      }

      if session.connectionState != .notConnected ||
         session.isBrowsing || session.isAdvertising {
        Button("Stop Connection Activities") {
          session.disconnect()
        }
        .padding(.top)
        .buttonStyle(.bordered)
        .tint(.red)
      }
    }
    .padding()
  }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
