# AnkiFlashcards KOReader — Backlog

## Reference: Anki "English" Note Type Fields

| Field       | Description                                      |
|-------------|--------------------------------------------------|
| `№`         | Card number (auto-assigned)                      |
| `Phrase`    | The highlighted word or phrase                   |
| `IPA`       | American English IPA transcription               |
| `Definition`| Context-aware definition (≤20 words)             |
| `Synonyms`  | 3–4 synonyms, comma-separated                    |
| `Text`      | Cloze sentence with `{{c1::phrase}}`             |
| `ImageFront`| `<img src="...">` — scene image (anime style)    |
| `ImageBack` | `<img src="...">` — same or alternate image      |
| `Sound`     | `[sound:...]` — pronunciation audio              |
| `Source`    | Cambridge Dictionary URL for the phrase          |

---

## DONE

### ✅ 1. Card Viewer — Front Side: Match Anki Generator App Template

Image at top + blanked cloze `[___]` + Synonyms. No labels, no hidden fields.
`card_viewer.lua` — `blank_cloze()` replaces `{{c1::phrase}}` with `[___]`.

### ✅ 2. Card Viewer — Back Side: Match Anki Generator App Template

Image + **Phrase** (bold) + IPA + Definition + Synonyms + revealed cloze + Source. No `[Label]` prefixes.
`card_viewer.lua` — `reveal_cloze()` replaces `{{c1::phrase}}` with the bare phrase.

### ✅ 3. Send Image to Anki via AnkiConnect

`anki_sync.lua` — replaced `picture` array with `storeMediaFile` + `ImageFront`/`ImageBack` fields.
Unique filename: `<phrase_slug>_<timestamp>.png`.

### ✅ Source Field: Cambridge Dictionary URL

`main.lua` — `cambridge_url()` generates `https://dictionary.cambridge.org/dictionary/english/<phrase-slug>` from the phrase. Matches `anki-card-generator` app logic.

### ✅ WiFi: Auto-prompt before card generation

`main.lua` — wrapped generation in `NetworkMgr:runWhenOnline()` so KOReader prompts to enable WiFi if off instead of failing with a socket error.

---

## TODO

### 4. Investigate: Light Anki Client Inside KOReader / Native Kobo App

**Priority:** Medium — Research

Investigate feasibility of implementing a spaced-repetition review session directly on the Kobo, syncing with Anki's scheduling data.

**Questions to answer:**
- Can AnkiConnect expose due cards and scheduling data (intervals, ease, due dates)?
  - Actions: `findCards`, `cardsInfo`, `answerCards`
- Is the Anki SM-2 scheduling algorithm simple enough to implement in Lua?
- Can we store scheduling state locally (due dates, intervals, ease factors) in the KOReader data dir?
- Two sync strategies:
  - **Online-only**: Fetch due cards from AnkiConnect over WiFi, answer on device, push results back
  - **Offline-first**: Sync deck to device when connected, review offline, push results on next connection
- KOReader UI constraints: no WebView, limited widget set — review UI would use `CardViewer`-style full-screen widgets with gesture/button input (Again / Hard / Good / Easy)
- Kobo-native alternative: standalone `.so` plugin or Python app via KFMon — higher complexity

**Deliverable:** A short feasibility note added to this file before committing to implementation.

---

### 5. (Out of Scope) Investigate: Own Anki-Compatible Platform

**Priority:** Low — Exploratory

Investigate building a self-hosted, Anki-compatible spaced repetition platform as a long-term alternative.

**Questions to answer:**
- What does the minimum viable SRS platform look like?
  - Card storage (SQLite or JSON), SM-2 or FSRS scheduling, review UI
- Can we expose an AnkiConnect-compatible HTTP API so existing tools (KOReader plugin, anki-card-generator) continue to work unchanged?
- Hosting options: local Mac app, self-hosted web app (FastAPI + SQLite), or cloud
- Sync between Kobo and platform: same AnkiConnect protocol over LAN/VPN
- Anki `.apkg` import/export for migration

**Deliverable:** Architecture sketch only — no implementation until item 4 is resolved.
