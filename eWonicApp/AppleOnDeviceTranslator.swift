import Translation

@available(iOS 26.0, *)
@MainActor
final class AppleOnDeviceTranslator {
  static let shared = AppleOnDeviceTranslator()
  private init() {}

  func translate(_ text: String, from src: String, to dst: String) async throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let srcN = normalize(src)
    let dstN = normalize(dst)

    let req = TranslationSession.Request(
      sourceText: trimmed,
      clientIdentifier: UUID().uuidString
    )

    let responses = try await SessionBroker.shared.responses(
      src: srcN,
      dst: dstN,
      requests: [req]
    )

    guard let first = responses.first else { return trimmed }
    return first.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalize(_ code: String) -> String {
    let s = code.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.contains("-") ? s : String(s.prefix(2))
  }
}
