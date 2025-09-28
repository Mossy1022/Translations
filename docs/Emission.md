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
