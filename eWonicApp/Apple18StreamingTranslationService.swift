//
//  Apple18StreamingTranslationService.swift
//  eWonicApp
//
//  Created by … on …
//

import SwiftUI
//import Translation

@available(iOS 18.4, *)
@MainActor
final class Apple18StreamingTranslationService {
    static let shared = Apple18StreamingTranslationService()
    private init() {}

//    private struct LivePair {
//        let host: UIHostingController<WorkerView>
////        let session: TranslationSession
//    }
//    private var cache: [String: LivePair] = [:]

    /// Consume a stream of source‐language tokens and produce a stream of translated tokens.
    /// - Parameters:
    ///   - chunks: AsyncSequence of partial‐speech tokens (e.g. from NativeSTTService.partialTokensStream())
    ///   - src: BCP-47 code of speaker’s language, e.g. “en-US”
    ///   - dst: BCP-47 code of listener’s language, e.g. “es-ES”
//    /// - Returns: AsyncThrowingStream<String, Error> that yields translated tokens as soon as they are available.
//    func stream<S: AsyncSequence>(
//        _ chunks: S,
//        from src: String,
//        to dst: String
//    ) async throws -> AsyncThrowingStream<String, Error> where S.Element == String {
//        let key = "\(src)>\(dst)"
//        let pair: LivePair
//        if let existing = cache[key] {
//            pair = existing
//        } else {
//            let newPair = try await makeLivePair(src: src, dst: dst)
//            cache[key] = newPair
//            pair = newPair
//        }
//
//        // ↦ This is the iOS 18.4+ call that returns a stream of translated tokens.
//        return 1;
////        return try await pair.session.streamingTranslator(for: chunks)
//    }

    // ───────────────────────────────────────────────────────────────────
    // MARK: – Private helpers to spin up an offscreen TranslationSession
//    private func makeLivePair(src: String, dst: String) async throws -> LivePair {
//        try await withCheckedThrowingContinuation { cont in
//            let cfg = TranslationSession.Configuration(
//                source: .init(identifier: String(src.prefix(2))),
//                target: .init(identifier: String(dst.prefix(2)))
//            )
//
//            var hostRef: UIHostingController<WorkerView>!
//            let worker = WorkerView(cfg: cfg) { result in
//                switch result {
//                case .success(let session):
//                    cont.resume(returning: LivePair(host: hostRef, session: session))
//                case .failure(let err):
//                    cont.resume(throwing: err)
//                }
//            }
//
//            hostRef = UIHostingController(rootView: worker)
//            hostRef.view.isHidden = true
//
//            // Present the hidden host so the TranslationSession can spin up.
//            if let root = UIApplication.shared
//                .connectedScenes
//                .compactMap({ $0 as? UIWindowScene })
//                .first?
//                .keyWindow?
//                .rootViewController {
//                root.present(hostRef, animated: false)
//            } else {
//                cont.resume(throwing: NSError(
//                    domain: "Translate",
//                    code: -2,
//                    userInfo: [NSLocalizedDescriptionKey: "No root VC to host translation"]
//                ))
//            }
//        }
//    }
//
//    private struct WorkerView: View {
//        let cfg: TranslationSession.Configuration
//        let done: (Result<TranslationSession, Error>) -> Void
//
//        var body: some View {
//            Color.clear.translationTask(cfg) { session in
//                done(.success(session))
//            }
//        }
//    }
    // ───────────────────────────────────────────────────────────────────
}
