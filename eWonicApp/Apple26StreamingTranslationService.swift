//
//  Apple26StreamingTranslationService.swift
//  eWonicApp
//
//  Token-level streaming translator using iOS 26 Translation framework.
//  Keeps one warm `TranslationSession` per language-pair.
//

import SwiftUI
import Translation

@available(iOS 26.0, *)
@MainActor
final class Apple26StreamingTranslationService {

  static let shared = Apple26StreamingTranslationService()
  private init() {}

  // MARK: - Cache
  private struct LivePair {
    let host: UIHostingController<WorkerView>
    let session: TranslationSession
  }
  private var cache: [String: LivePair] = [:]

  // MARK: - Public
  /// Pipe source-language tokens in, receive translated tokens out.
    func stream<S>(
      _ src_tokens: S,
      from src_lang: String,
      to   dst_lang: String
    ) async throws -> AsyncThrowingStream<String,Error>
    where S: AsyncSequence & Sendable,          // ← add Sendable
          S.AsyncIterator: Sendable,
          S.Element == String {

      let key  = "\(src_lang)>\(dst_lang)"
      let pair = try await cachedPair(src: src_lang, dst: dst_lang, key: key)

      return AsyncThrowingStream { cont in
        // run on the same actor → no sendability issue
        Task { @MainActor in
          do {
            try await pair.session.prepareTranslation()
            for try await token in src_tokens {
              let resp = try await pair.session.translate(token)
              cont.yield(resp.targetText)
            }
            cont.finish()
          } catch {
            cont.finish(throwing: error)
          }
        }
      }
    }

  // MARK: - Helper to obtain / cache a live session
  private func cachedPair(src: String, dst: String, key: String) async throws -> LivePair {
    if let existing = cache[key] { return existing }

    return try await withCheckedThrowingContinuation { cont in
      let cfg = TranslationSession.Configuration(
        source: .init(identifier: src),
        target: .init(identifier: dst)
      )

      var host_ref: UIHostingController<WorkerView>!
      let worker = WorkerView(cfg: cfg) { result in
        switch result {
        case .success(let session):
          let pair = LivePair(host: host_ref, session: session)
            self.cache[key] = pair
          cont.resume(returning: pair)
        case .failure(let err):
          cont.resume(throwing: err)
        }
      }

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
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "No root VC for TranslationSession"]
        ))
        return
      }
      root.present(host_ref, animated: false)
    }
  }

  // MARK: - WorkerView
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
