**Timing**
- Stable cutoff (One‑Phone): **1.3s** (±0.2s)
- Long-speech cap: **7s**
- Early-TTS bailout (Peer): **6–10s**; min chunk **≥24**
- Post-TTS grace: **1.0–1.5s** (route-aware; BT ≈ 1.4–1.6s)
- Retarget window (One‑Phone): **~2.0s**, **max 1 flip/phrase**
- Inter‑TTS gap cap: **≤150ms**

**Language vote weights**
- NLRecognizer conf (native)
- Accent boost: **+0.25** (ES)
- Stopword ratio: **+0.15**
- Same‑speaker priors: **+0.20 / +0.10 / +0.05**

**RMS curve**
- `threshold = base + (1 – sensitivity) × delta`

**Backoff (Azure path)**
- **0.5 → 1 → 2s** (cap); banner after **3+** retries

**Queues & caches**
- Phrase queue max depth alert at **5**
- TranslationSession cache: **en→es**, **es→en** only (LRU others)

**Acceptance bars**
- Commit→TTS start p50 ≤ **300ms**, p95 ≤ **450ms**
- Echo events: **0** in 30‑min session
- Thermal stable for **20min** continuous dialog
- Reconnect: ≤ **1** missed turn during 10‑s AWDL drop

**Purity & Cleanup**

- MIN_PURITY_EN = 0.75, MIN_PURITY_ES = 0.75
- CLEANUP_MAX_TOKEN_LEN = 12
- CLEANUP_ALLOWED_PASSTHROUGH = { properNoun, number, date, currency, URL }
- CLEANUP_MAX_STEPS = 2 (1 selective token pass + 1 full retry)

**Flip Policy (One-Phone, capture-only)**
- FLIP_POLICY = balanced (values: none | conservative | balanced)
- FLIP_MARGIN = 0.30–0.35 for FLIP_DWELL_MS = 400–600
- FLIP_MAX_PER_PHRASE = 1