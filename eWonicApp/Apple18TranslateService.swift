//
//  Apple18TranslateService.swift
//  eWonicApp
//
//  iOS 18-only on-device translation (no UI shown).
//

import SwiftUI
import Translation                     // iOS 18 SDK

@available(iOS 18.0, *)
@MainActor                               // keep everything on the main actor
final class Apple18TranslateService {

  static let shared = Apple18TranslateService()
  private init() {}

  // --------------------------------------------------------------------
  // Public async API
  // --------------------------------------------------------------------
  func translate(_ text: String,
                 from src: String,
                 to   dst: String) async throws -> String {

    try await withCheckedThrowingContinuation { cont in

      // Invisible SwiftUI worker that performs the translation
      let host = UIHostingController(
        rootView: WorkerView(
          text: text,
          src: Locale.Language(identifier: String(src.prefix(2))),
          dst: Locale.Language(identifier: String(dst.prefix(2)))) {
            cont.resume(with: $0)       // forward the Result back out
          })

      host.view.isHidden = true        // keep it off-screen

      // Present modally so the view lifecycle (and .translationTask)
      // becomes active.  UIWindowScene-safe from iOS 15 onward.
      guard
        let windowScene = UIApplication.shared.connectedScenes
                             .compactMap({ $0 as? UIWindowScene }).first,
        let root = windowScene.keyWindow?.rootViewController
      else {
        cont.resume(throwing: NSError(
          domain: "Translate", code:-2,
          userInfo:[NSLocalizedDescriptionKey:"No root VC"]))
        return
      }
      root.present(host, animated: false)
    }
  }

  // --------------------------------------------------------------------
  // Hidden SwiftUI helper view
  // --------------------------------------------------------------------
  private struct WorkerView: View {
    let text: String
    let src: Locale.Language
    let dst: Locale.Language
    let done: (Result<String,Error>) -> Void

    var body: some View {
      // 1️⃣ Create a config for the requested language pair
      // 2️⃣ Attach .translationTask – Apple drives the TranslationSession
      // 3️⃣ Pull the translated text out of the Response object
      Color.clear
        .translationTask(
          TranslationSession.Configuration(
            source: src,
            target: dst)) { session in
              Task {
                do {
                  let response = try await session.translate(text)
                  done(.success(response.targetText))
                } catch {
                  done(.failure(error))
                }
              }
            }
    }
  }
}
