**Manual**
- Echo test (table, high volume) → 0 echo.
- Long monologue (Peer) → interim ≤ ~8s; final tail present.
- Mid‑sentence pause → 0.8–1.2s no emit; 1.5–2.0s emits.
- Ping‑pong (One‑Phone) → exactly one flip/phrase; no missed starts.
- Same‑speaker long run (One‑Phone) → stable language via priors; no mid‑phrase flips.
- Network flake (pre‑26) → backoff + banner; stable UI; clean resume.
- Multipeer dupes → LRU drops.
- Route changes → speaker↔AirPods↔hearing aids; dynamic grace works.
- Thermal soak → 25‑min dialog on iPhone 12/13/SE.

**Mixed-language output tests**

- Short EN→ES greeting (“Hey, how are you?”) should not produce “Hola how are tu”.
- Proper noun passthrough: “Voy a Starbucks a las 3:00 pm” keeps Starbucks and time format, rest in ES.

**Flip policy A/B (One-Phone)**

- .none vs .balanced: measure WER and commit accuracy on 100 short utterances; confirm no stutter and commit→TTS p95 ≤ 450ms in both.

**Purity budget**

- With cleanup enabled, 95% of commits keep commit→TTS ≤ 450ms; if exceeded, verify best-so-far speech still triggers on time.

**Data decks**
- Spanglish 200‑phrase set (names/dates/currency) → commit accuracy & MT fidelity.
- Noise profiles (café, car@60mph, wind) → tune RMS & stable windows.