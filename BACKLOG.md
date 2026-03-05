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

#### ✅ 4. Deck Per Book

Automatically route cards to a deck named after the current book: `English::<book_title>` instead of the fixed `English::Koreader` deck.

`anki_sync.lua` — `build_deck_name(config, card)` derives the top-level parent from `config.deck` and appends `::<book_title>` (colon-sanitised). Falls back to `config.deck or "English::Koreader"` when no title is present.

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

#### ✅ 7. Highlight Inbox — Batch Card Creation

Browse all highlights from the current book and select which ones to convert to flashcards.

`highlight_inbox.lua` — reads `ui.annotation.annotations` (filters by `ann.drawer`), shows a scrollable Menu with ☐/☑/✓ prefixes. "▶ Generate Selected (N)" button runs sequential AI generation via `UIManager:scheduleIn` with live progress notification. Already-carded highlights shown with ✓ and non-tappable. Entry point: "📥 Highlight Inbox" added as Entry 3 in the highlight dialog.

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

#### ✅ 9. Navigate to Source — Jump Back to Highlighted Phrase

When reviewing a flashcard from My Cards, a "Go to" button navigates back to the original highlighted phrase in the book.

`card_storage.lua` — stores `highlight_pos0`/`highlight_pos1` with the card. `card_manager.lua` — passes `ui` reference and wires `on_navigate_to_source` callback using `GotoXPointer`/`GotoPage` events. `card_viewer.lua` — shows "Go to" button (text, not emoji — e-ink can't render emojis). Only shown in My Cards viewer, not during card creation (user is already at the highlight).

---

#### ✅ 10. My Cards — Default to Current Book

When opening "My Cards" from the highlight menu, the list defaults to cards from the current book.

`main.lua` — passes `book_title` and `self.ui` to `CardManager.show()`. User can still clear the filter to see all cards.

---

#### ✅ 11. Context Crafter — Regenerate Example Sentence

"Regen sentence" button in the Edit dialog: asks AI to regenerate only the cloze `Text` field + `image_prompt` with a fresh sentence. Also kicks off a new image generation with the updated prompt.

`card_generator.lua` — `generate_text()` with a sentence-only prompt returning `text` + `image_prompt`. Wired in `main.lua` and `card_manager.lua` via `on_regen_text` callback.

---

#### ✅ 12. Art Director — Regenerate Image Only

"Regen image" button in the Edit dialog: triggers a new DashScope image generation using the existing `image_prompt` without regenerating any text. `image_prompt` is now persisted in `card_storage.lua` so it works for saved cards opened from My Cards.

Wired in `main.lua` and `card_manager.lua` via `on_regen_image` callback.

---

### Dropped / Out of Scope

#### ~~Light Anki Review Client~~ — Rejected

Storage bloat (synced images/audio = hundreds of MB), no audio playback in KOReader Lua plugins, e-ink latency for review UX, and bi-directional SM-2 sync complexity all make this inferior to native Anki. The Kobo's role is creation, not review.

#### ~~Own Anki-Compatible SRS Platform~~ — Deferred indefinitely

Requires resolving the review client feasibility first. Out of scope until items 4–8 are complete.
