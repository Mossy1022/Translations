**Echo bleed** → Check `.voiceChat`, ref‑counts, `isSpeaking` pause.

**Floor contention** → Floor token = device playing TTS; release on finish + grace.

**Late translations** → Peer early streaming + bailout (~8s); One‑Phone holds to commit.

**Premature cutoff** → Stable ≥1.0–1.5s; density + growth checks; whitespace/punct dwell (K ms).

**Turn overlap at TTS end** → Single resume token; cancel before reuse.

**Wrong-language (One‑Phone)** → Lock at commit; 2.0s next‑phrase retarget; one flip max; bias by last speaker.

**Service swap race** → Single `captureIsActive`; idempotent start/stop; cancel timers first.

**Azure cancel loop** → Backoff 0.5→1→2s; banner after 3+; freeze until user restarts.

**Multipeer dupes/out‑of‑order** → UUID LRU + timestamp/seq ordering; 500ms reorder window.

**Audio session flapping** → `.isBusy` benign; no modals; ref‑counted begin/end.

**Routing changes (BT/MFi)** → Route‑aware grace; fade 100–200ms; resume once.

**Performance/thermal** → Low‑power mode: lower sample rate, slightly lower TTS quality, raise cap to 8–9s to insert idle.
