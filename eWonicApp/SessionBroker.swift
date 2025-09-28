import SwiftUI
import UIKit
import Translation

@available(iOS 26.0, *)
@MainActor
final class SessionBroker {
  static let shared = SessionBroker()

  struct Key: Hashable { let src: String; let dst: String }

  private struct LivePair {
    let window: UIWindow
    let host: UIHostingController<SessionHostView>
    let session: TranslationSession
  }

  private var live: [Key: LivePair] = [:]
  private var inflight: [Key: [CheckedContinuation<LivePair, Error>]] = [:]

  func responses(src: String,
                 dst: String,
                 requests: [TranslationSession.Request]) async throws -> [TranslationSession.Response] {
    let key = Key(src: src, dst: dst)
    let pair = try await pairForKey(key)
    return try await pair.session.translations(from: requests)
  }

  private func pairForKey(_ key: Key) async throws -> LivePair {
    if let p = live[key] { return p }

    if inflight[key] != nil {
      return try await withCheckedThrowingContinuation { inflight[key]!.append($0) }
    }
    inflight[key] = []

    return try await withCheckedThrowingContinuation { cont in
      let cfg = TranslationSession.Configuration(
        source: .init(identifier: key.src),
        target: .init(identifier: key.dst)
      )

      // Declare these first so the closure can capture them safely.
      var hostRef: UIHostingController<SessionHostView>!
      var overlay: UIWindow!

      let view = SessionHostView(configuration: cfg) { result in
        switch result {
        case .success(let session):
          let pair = LivePair(window: overlay, host: hostRef, session: session)
          self.live[key] = pair
          cont.resume(returning: pair)
          self.inflight[key]?.forEach { $0.resume(returning: pair) }
          self.inflight[key] = nil

        case .failure(let error):
          cont.resume(throwing: error)
          self.inflight[key]?.forEach { $0.resume(throwing: error) }
          self.inflight[key] = nil
        }
      }

      // Build an offscreen window so SwiftUI stays active without view-hierarchy warnings.
      guard let scene = UIApplication.shared.connectedScenes
              .compactMap({ $0 as? UIWindowScene })
              .first else {
        cont.resume(throwing: NSError(
          domain: "Translation",
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "No UIWindowScene for TranslationSession"]
        ))
        return
      }

      hostRef = UIHostingController(rootView: view)
      hostRef.view.backgroundColor = .clear
      hostRef.view.isUserInteractionEnabled = false

      overlay = UIWindow(windowScene: scene)
      overlay.windowLevel = .statusBar + 1      // invisible overlay
      overlay.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
      overlay.rootViewController = hostRef
      overlay.isHidden = false                  // keep view hierarchy alive
    }
  }
}

@available(iOS 26.0, *)
private struct SessionHostView: View {
  let configuration: TranslationSession.Configuration
  let ready: (Result<TranslationSession, Error>) -> Void

  var body: some View {
    Color.clear
      .translationTask(configuration) { session in
        ready(.success(session))
      }
  }
}
