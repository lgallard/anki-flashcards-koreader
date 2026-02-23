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

### Strategic Direction

**Kobo = world's best card creation on-ramp. Anki = review engine.**

The plugin's goal is to make the highlight→flashcard pipeline as frictionless and intelligent as possible, feeding a high-quality stream of cards into Anki for review. A light Anki review client on Kobo was considered and rejected: storage bloat (images/audio = hundreds of MB), no audio playback in Lua plugins, e-ink latency, and bi-directional sync complexity all make it inferior to native Anki.

---

### Tier 1 — Quick Wins

#### 4. Deck Per Book

**Priority:** High — Trivial effort

Automatically route cards to a deck named after the current book: `English::<book_title>` instead of the fixed `English::Koreader` deck.

- `book_title` is already stored on every card (`card.book_title`)
- Change `config.deck` fallback in `anki_sync.lua`: use `card.book_title` when available
- Sanitise the title (strip special chars) to produce a valid Anki deck name
- Example: reading *The Power of Habit* → cards go to `English::The Power of Habit`

---

#### 5. Duplicate Detection

**Priority:** High — Low effort

Before generating a card, query AnkiConnect to check whether a card for that phrase already exists in the collection. Skip generation and notify the user if a duplicate is found.

- AnkiConnect action: `findNotes` with query `"Phrase:<phrase> deck:English"`
- Call this check before showing the loading notification
- Show "Already in Anki" notification if a duplicate exists
- Avoids bloating the deck with repeated words across re-reads

---

#### 6. Auto-Send on WiFi

**Priority:** High — Medium effort

When the Kobo connects to WiFi (e.g., for sync or browsing), silently flush all unsent locally-saved cards to AnkiConnect in the background.

- Use `NetworkMgr` event/callback to detect WiFi becoming available
- Trigger `AnkiSync.send_card` for each unsent card in `CardStorage.load_cards()`
- Show a brief notification: "3 cards sent to Anki"
- No user action required — cards appear in Anki automatically

---

### Tier 2 — Core Experience Upgrade

#### 7. Highlight Inbox — Batch Card Creation

**Priority:** High — Medium effort

Browse all highlights from the current book and select which ones to convert to flashcards. Replaces the interruptive one-by-one generation flow with a focused end-of-chapter batch session.

- Access KOReader's highlight database (`ui/widget/bookstatuswidget` or the reader's highlight API)
- Show a scrollable list of all highlights for the current book
- User taps to select/deselect highlights
- Tap "Generate Selected" → AI generates cards sequentially with a progress indicator
- Already-carded highlights are marked (greyed out or checkmarked)
- Respects reading flow: no interruption mid-sentence

---

#### 8. Per-Book Progress Dashboard

**Priority:** Medium — Low effort

A stats screen showing vocabulary progress per book: highlights converted, cards created, cards sent to Anki.

- Data is already available: `book_title` + `book_author` on every stored card
- Group `CardStorage.load_cards()` by `book_title`
- Show per-book counts: created / sent / unsent
- Accessible from the "📚 My Cards" menu as a "📊 Stats" entry

---

### Tier 3 — Polish

#### 9. Context Crafter — Regenerate Example Sentence

**Priority:** Medium

"Simpler example" button on the card back: asks AI to regenerate only the cloze `Text` field with a cleaner or simpler sentence. Useful when the AI-generated sentence is awkward or too complex.

---

#### 10. Art Director — Regenerate Image Only

**Priority:** Medium

"New image" button that triggers a new DashScope image generation without regenerating the full card. Useful when the image doesn't match the card's meaning.

---

#### 11. Lexical Linker — Related Word Suggestions

**Priority:** Low

After a card is generated, the AI suggests 2–3 related word-family terms (e.g., after carding "decisive" → suggests "decide", "indecisive", "decision"). One tap queues them for card generation.

---

### Dropped / Out of Scope

#### ~~Light Anki Review Client~~ — Rejected

Storage bloat (synced images/audio = hundreds of MB), no audio playback in KOReader Lua plugins, e-ink latency for review UX, and bi-directional SM-2 sync complexity all make this inferior to native Anki. The Kobo's role is creation, not review.

#### ~~Own Anki-Compatible SRS Platform~~ — Deferred indefinitely

Requires resolving the review client feasibility first. Out of scope until items 4–8 are complete.
