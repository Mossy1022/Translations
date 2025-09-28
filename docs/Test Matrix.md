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

**Data decks**
- Spanglish 200‑phrase set (names/dates/currency) → commit accuracy & MT fidelity.
- Noise profiles (café, car@60mph, wind) → tune RMS & stable windows.