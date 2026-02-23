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
| `Source`    | Book title — Author                              |

---

## TODO

### 1. Card Viewer — Front Side: Match Anki Generator App Template

**Priority:** High

The front side of the card viewer in KOReader must match the Anki front template:
- Show the **AI-generated image** (ImageFront) at the top
- Show the **cloze sentence** (`Text` field) with the key word visually blanked or highlighted — e.g. `Her [___] discovery changed everything.`
- Show **Synonyms** below the cloze sentence
- Do NOT show Phrase, IPA, Definition, or Source on the front

Currently the front shows all fields with `[Label]` prefixes — this needs to be redesigned to match the Anki card experience.

**Reference:** `anki-card-generator/src/anki_exporter.py` — `ImageFront` + `Text` + `Synonyms` fields.

---

### 2. Card Viewer — Back Side: Match Anki Generator App Template

**Priority:** High

The back side must match the Anki back template:
- Show the **AI-generated image** (ImageBack / same image) at the top
- Show **Phrase** (large, prominent)
- Show **IPA** below the phrase
- Show **Definition**
- Show **Synonyms**
- Show the **full cloze sentence** (with the word revealed, not blanked)
- Show **Source** at the bottom (small/muted)
- Remove all `[Label]` prefixes (`[Phrase]`, `[IPA]`, `[Definition]`, etc.) — the layout itself communicates the structure

---

### 3. Send Image to Anki via AnkiConnect

**Priority:** High

When tapping "→ Anki", the card image must be uploaded to Anki's media collection and referenced in the `ImageFront` and `ImageBack` fields.

Current state: `anki_sync.lua` sends image bytes via the `picture` array in `addNote`, but this doesn't populate the `ImageFront`/`ImageBack` fields correctly for the "English" note type.

**Required approach** (matching `anki_exporter.py`):
1. Read image file from device (`card.image_path`)
2. Generate a unique filename: `<phrase>_<timestamp>.png`
3. Call `storeMediaFile` AnkiConnect action with base64-encoded image data
4. Set `ImageFront` field to `<img src="<filename>">`
5. Set `ImageBack` field to the same `<img src="<filename>">`
6. Remove the current `picture` array approach from `addNote`

**Reference:** `anki-card-generator/src/anki_exporter.py` — `store_media_file()` + `add_card_to_anki()`.

---

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
