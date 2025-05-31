//
//  Apple18TranslationService.swift
//  eWonicApp
//
//  Persistent on‑device translation service (iOS 18‑only).
//  Caches one TranslationSession per language‑pair so the model
//  stays warm for the whole conversation.
//
import SwiftUI
import Translation

@available(iOS 18.0, *)
@MainActor
final class Apple18TranslationService {
  static let shared = Apple18TranslationService()      // ← note the class name
  private init() {}

  // One live worker per "src>dst" key.
  private struct LivePair {
    let host: UIHostingController<WorkerView>
    let session: TranslationSession
  }
  private var cache: [String: LivePair] = [:]

  /// Translate with a cached TranslationSession (or create a new one).
  func translate(_ text: String,
                 from src: String,
                 to   dst: String) async throws -> String {
    let key = "\(src)>\(dst)"
    let pair: LivePair

    if let live = cache[key] {
      pair = live
    } else {
      pair = try await makeLivePair(src: src, dst: dst)
      cache[key] = pair
    }

    let response = try await pair.session.translate(text)
    return response.targetText
  }

  // MARK: – Private helpers
    private func makeLivePair(src: String, dst: String) async throws -> LivePair {
        try await withCheckedThrowingContinuation { cont in
          let cfg = TranslationSession.Configuration(
            source: .init(identifier: String(src.prefix(2))),
            target: .init(identifier: String(dst.prefix(2))))

          var hostRef: UIHostingController<WorkerView>!
          let worker = WorkerView(cfg: cfg) { result in
            switch result {
            case .success(let session): cont.resume(returning: LivePair(host: hostRef, session: session))
            case .failure(let err):     cont.resume(throwing: err)
            }
          }
          hostRef = UIHostingController(rootView: worker)
          hostRef.view.isHidden = true

          guard let rootVC = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).first?
                            .keyWindow?.rootViewController
          else {
            cont.resume(throwing: NSError(domain: "Translate", code: -2,
                                          userInfo: [NSLocalizedDescriptionKey: "No root VC"]))
            return
          }
          rootVC.present(hostRef, animated: false)
        }
      }

  // Off‑screen worker view that owns the TranslationSession.
  private struct WorkerView: View {
    let cfg: TranslationSession.Configuration
    let done: (Result<TranslationSession, Error>) -> Void

    var body: some View {
      Color.clear.translationTask(cfg) { session in
        done(.success(session))
      }
    }
  }
}
