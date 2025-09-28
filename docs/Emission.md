**Peer / Convention**
- Prefer sentence-boundary emission; bailout timer **6–10s**; min chunk length **≥24 chars**.
- Maintain `earlyTTSSentPrefix`; never double-emit; finals must include unsent tail.

**One‑Phone (phrase-commit)**
- Translate/speak **only at phrase commit**:
  - punctuation **or**
  - stable cutoff ~**1.3s** (±0.2s) **or**
  - long-speech cap **7s**.
- Maintain a **FIFO phrase queue**: capture continues while TTS drains queue.
- Allow **barge-in** if queue depth > 1 (stop at safe boundary) or enforce ≤150ms inter-gap.

**Disfluencies & conjunction tail**
- If last token is a conjunction (`and/y/que/that`) or clear filler, delay commit.

**Telemetry**
- Log commit size, commit→TTS latency; queue depth.

**Target-Language Purity Guard (One-Phone commit)**

**Goal:** avoid hybrid outputs like “Hola how are tu”.

**When:**

- One-Phone: immediately after srcFull → dstFull translation at phrase commit.
- Peer (receiver): after any one-pass translation from payload language → my language.

**Algorithm (single, bounded repair)**

1. Compute purity via heuristic stopword ratio (you already have purity(of:expectedTargetBase:)).

2. If purity < MIN_PURITY(target) (see Tunables.md), run cleanup once:
   - Token-tag with NLTagger for language.
   - For tokens/spans not in the target language and not whitelisted entities (proper nouns, numbers, dates, currency, URLs), translate those spans in place using the on-device path.

3. Recompute purity. If still low, do one full re-translate of the entire phrase.

4. Cap at 1 cleanup + 1 retry. Never loop.

**Passthrough whitelist**: proper nouns, numbers, dates, currency, URLs only. No passthrough for common interjections/pronouns.

**Latency rule:** if cleanup would break the commit→TTS p95 ≤ 450ms budget, speak best-so-far; finish cleanup for on-screen text only.