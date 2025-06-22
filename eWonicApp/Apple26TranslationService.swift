//
//  Apple26TranslationService.swift
//  eWonicApp
//
//  One-shot, sentence-level on-device translator (iOS 26).
//

import SwiftUI
import Translation

@available(iOS 26.0, *)
@MainActor
struct Apple26TranslationService {

  /// Translate *text* once — no streaming.
  static func translate(
    _ text: String,
    from src_lang: String,          // e.g. "en-US"
    to   dst_lang: String           // e.g. "es-ES"
  ) async throws -> String {

    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ""
    }

    // Wrap the whole dance in a continuation so callers see a
    // simple `async throws -> String`.
    return try await withCheckedThrowingContinuation { cont in

      // 1. Build configuration.
      let cfg = TranslationSession.Configuration(
        source: .init(identifier: src_lang),
        target: .init(identifier: dst_lang)
      )

      // 2. Create an off-screen SwiftUI host that requests a session.
      var host_ref: UIHostingController<WorkerView>!
      let worker = WorkerView(cfg: cfg) { result in
        switch result {
        case .success(let session):
          Task {
            do {
              // Prepare models if necessary (downloads once, then cached).
              try await session.prepareTranslation()
              let resp  = try await session.translate(text)
              cont.resume(returning: resp.targetText)
            } catch {
              cont.resume(throwing: error)
            }
          }
        case .failure(let err):
          cont.resume(throwing: err)
        }
      }

      // 3. Present invisibly so the session can be created.
      host_ref = UIHostingController(rootView: worker)
      host_ref.view.isHidden = true
      guard
        let root = UIApplication.shared
          .connectedScenes
          .compactMap({ $0 as? UIWindowScene })
          .first?
          .keyWindow?
          .rootViewController
      else {
        cont.resume(throwing: NSError(
          domain: "Translate",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "No root VC for TranslationSession"]
        ))
        return
      }
      root.present(host_ref, animated: false)
    }
  }

  // MARK: - WorkerView
  /// Off-screen helper that hands back a ready `TranslationSession`.
  private struct WorkerView: View {
    let cfg: TranslationSession.Configuration
    let done: (Result<TranslationSession,Error>) -> Void

    var body: some View {
      Color.clear
        .translationTask(cfg) { session in
          done(.success(session))
        }
    }
  }
}
