**Goal:** Robust EN↔ES decision **per phrase** (no mid-phrase flips); fast correction only at next phrase start.

**Rolling vote features**
- `NLRecognizer` base-2 + confidence.
- Accent/diacritic hits (`[áéíóúñ¿¡]`) → **+0.25** to ES.
- Stopword ratio (tiny lists per lang) → **+0.15** to winner.
- Prior for continuing same speaker → **+0.20 / +0.10 / +0.05** decaying across consecutive phrases.

**Lock & retarget (capture-only; never affects mid-phrase audio)**

- Lock language at phrase commit. No flips within a phrase.
- Retarget window for the next phrase only: first ~2.0s of the new phrase may flip the STT locale once if early evidence strongly contradicts the bias. This improves recognition only; we still do not speak until that phrase commits.
- Suggested thresholds (see Tunables.md):
  - Flip when vote margin ≥ 0.30–0.35 for ≥ 400–600ms.
  - Max flips/phrase = 1 

**Code-switching & entities**
- Entity passthrough: names, numbers, dates kept if ASR confidence low.

**Acceptance**
- Wrong-language commits: quiet ≤ **1%**, noisy café ≤ **3%**.
- Note: Retarget affects STT accuracy only; final audio language is chosen at commit (never during partials).