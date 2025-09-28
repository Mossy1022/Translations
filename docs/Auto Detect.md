**Goal:** Robust EN↔ES decision **per phrase** (no mid-phrase flips); fast correction only at next phrase start.

**Rolling vote features**
- `NLRecognizer` base-2 + confidence.
- Accent/diacritic hits (`[áéíóúñ¿¡]`) → **+0.25** to ES.
- Stopword ratio (tiny lists per lang) → **+0.15** to winner.
- Prior for continuing same speaker → **+0.20 / +0.10 / +0.05** decaying across consecutive phrases.

**Lock & retarget**
- Lock at **phrase commit**. **No flips** within phrase.
- Next phrase: 2.0s **retarget window**, **max 1** flip, then freeze.
- If confidence below threshold, stick to bias (last speaker).

**Code-switching & entities**
- Entity passthrough: names, numbers, dates kept if ASR confidence low.

**Acceptance**
- Wrong-language commits: quiet ≤ **1%**, noisy café ≤ **3%**.