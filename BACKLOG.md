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

#### ✅ 5. Skip Duplicate Highlight on Card Creation

Before `rhi:saveHighlight()`, checks `ui.annotation.annotations` for an existing highlight at the same `pos0`/`pos1` — skips saving if already highlighted.

`main.lua` — loops through annotations before calling `rhi:saveHighlight()`.

---

#### ✅ 6. Auto-Send on WiFi

Polls every 60s (first check after 30s). When WiFi is on and `auto_send_wifi` is enabled in settings, flushes all unsent cards to AnkiConnect and shows a notification with the count.

`main.lua` — `auto_send_tick()` scheduler in `init()`. `settings_viewer.lua` — tap-to-toggle button for the setting (disabled by default).

---

### Tier 2 — Core Experience Upgrade

#### ✅ 7. Highlight Inbox — Batch Card Creation

Browse all highlights from the current book and select which ones to convert to flashcards.

`highlight_inbox.lua` — reads `ui.annotation.annotations` (filters by `ann.drawer`), shows a scrollable Menu with ☐/☑/✓ prefixes. "▶ Generate Selected (N)" button runs sequential AI generation via `UIManager:scheduleIn` with live progress notification. Already-carded highlights shown with ✓ and non-tappable. Entry point: "📥 Highlight Inbox" added as Entry 3 in the highlight dialog.

---

#### ✅ 8. Per-Book Progress Dashboard

Per-book stats screen showing total/sent/unsent card counts, accessible from Manage > Stats by Book.

`card_manager.lua` — `show_stats()` groups `CardStorage.load_cards()` by `book_title` and displays per-book breakdowns in a Menu widget.

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

### Tier 4 — Multi-Provider Support

#### 13. OpenAI (ChatGPT) Support — Text + Image Generation

**Priority:** Medium

Add OpenAI as an alternative provider for both text and image generation. The plugin already uses an OpenAI-compatible chat completions endpoint — the main work is allowing users to configure a different base URL, API key, and image model.

**Text generation:**
- OpenAI endpoint: `https://api.openai.com/v1/chat/completions`
- Default model: `gpt-4o-mini` (cost-effective) or `gpt-4o`
- Reuse existing prompt templates — OpenAI uses the same chat completions format

**Image generation:**
- GPT Image 1 Mini: $0.005–0.05/image (cheapest paid option)
- DALL-E 3: $0.04–0.12/image (higher quality)
- Uses the OpenAI images API — simpler than DashScope async polling

---

#### 14. Pollinations.ai (Flux) Support — Image Generation Only

**Priority:** Medium

Add [Pollinations.ai](https://pollinations.ai/) as a free alternative image generation provider using Flux models. Useful for users who want to avoid image generation costs entirely.

- Free HTTP API — no API key required
- Endpoint: `https://image.pollinations.ai/prompt/<url_encoded_prompt>`
- Returns image directly (no async polling needed — simpler than DashScope)
- Add `image_provider` setting: `dashscope` (default), `pollinations`, `openai`, `gemini`
- Adapt `image_generator.lua` to support multiple providers

---

#### 15. Google Gemini Support — Text + Image Generation

**Priority:** Medium

Add Google Gemini as an alternative provider for both text and image generation. Gemini's free tier is very generous — 500 image generations/day with no credit card required.

**Text generation:**
- Gemini API endpoint: `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`
- Default model: `gemini-2.0-flash` (fast, cost-effective)
- Requires adapting the request/response format (Gemini uses a different schema than OpenAI-compatible endpoints)

**Image generation:**
- Gemini 2.5 Flash: free tier (500/day), ~$0.04/image on paid tier
- Imagen 4 Fast: $0.02/image (cheaper than DashScope)
- Single API key covers both text and image — no separate image provider needed

---

#### 16. OpenRouter Support — Text Generation

**Priority:** Medium

Add [OpenRouter](https://openrouter.ai/) as an alternative text generation provider. OpenRouter is an OpenAI-compatible API gateway that gives access to hundreds of models (Claude, GPT, Llama, Mistral, Gemma, etc.) through a single API key and endpoint.

- OpenRouter endpoint: `https://openrouter.ai/api/v1/chat/completions`
- Uses the same OpenAI-compatible chat completions format — minimal adapter work
- Add `text_provider` setting: `dashscope` (default), `openai`, `gemini`, `openrouter`
- Configure via `openrouter_api_key` + optional `openrouter_model` in settings
- Default model: `anthropic/claude-haiku` or `meta-llama/llama-3-8b-instruct` (cost-effective)
- Users can pick any model from OpenRouter's catalog via the model setting
- No image generation — pair with an image provider (`dashscope`, `pollinations`, `openai`, `gemini`)

---

### Tier 5 — Multi-Device Sync

#### ✅ 17. Cloud Sync — Sync Cards Between Kobo Devices via Dropbox/WebDAV

Sync `anki_flashcards.json` across multiple Kobo devices using KOReader's built-in `SyncService` (Dropbox/WebDAV). Three-way JSON merge handles adds, deletes, and conflicts by `updated_at` timestamp.

`card_sync.lua` — merge callback with card identity `normalize(phrase)__normalize(book_title)`, sync runner, and Cloud Sync UI dialog (Sync Now / Change Server / Remove Server). `card_storage.lua` — added `updated_at = os.time()` in `save_card()` and `update_card()`. `settings_viewer.lua` — Cloud Sync button row. `main.lua` — silent auto-sync 45s after startup (only when already online).

Images are not synced (device-local paths). Synced cards auto-regenerate images when opened if online.

---

#### ✅ 18. Tap-to-Zoom on Card Images

Tapping the image in the card viewer opens KOReader's full-screen `ImageViewer` with pinch-to-zoom and pan support.

`card_viewer.lua` — stores image widget reference, intercepts tap in `onTapClose` before close logic, opens `ImageViewer` when tap lands on image.

---

#### ✅ 19. Auto-Regenerate Images on Synced Cards

Cards imported via cloud sync arrive without images. When opened (tap-to-show or My Cards), if the card has an `image_prompt` but no `image_path` and WiFi is connected, image generation starts automatically in the background. Silent failure if offline.

`main.lua` — auto-regen in tap-to-show viewer. `card_manager.lua` — auto-regen in card list viewer.

---

#### ✅ 20. Regen Image in Tap-to-Show Viewer

Added `on_regen_image` callback to the tap-to-show card viewer (triggered when tapping a highlight with a saved card). Previously only available during initial card creation and in the card manager.

`main.lua` — wired `on_regen_image` in the tap-to-show `make_viewer` function.

---

### Dropped / Out of Scope

#### ~~Light Anki Review Client~~ — Rejected

Storage bloat (synced images/audio = hundreds of MB), no audio playback in KOReader Lua plugins, e-ink latency for review UX, and bi-directional SM-2 sync complexity all make this inferior to native Anki. The Kobo's role is creation, not review.

#### ~~Own Anki-Compatible SRS Platform~~ — Deferred indefinitely

Requires resolving the review client feasibility first. Out of scope until items 4–8 are complete.
