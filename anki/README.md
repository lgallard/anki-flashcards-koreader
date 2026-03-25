# Anki Note Type

This folder contains the **Vocabulary** note type definition used by the AnkiFlashcards plugin.

## Fields

| # | Field | Description |
|---|-------|-------------|
| 1 | `Phrase` | Canonical form of the phrase (base/infinitive, lowercase) |
| 2 | `IPA` | Pronunciation notation (IPA, pinyin, romaji, etc.) |
| 3 | `Definition` | Context-aware definition (up to 20 words) |
| 4 | `Synonyms` | 3–4 synonyms, comma-separated |
| 5 | `Text` | Cloze example sentence using `{{c1::...}}` |
| 6 | `Source` | Dictionary URL for the phrase |
| 7 | `ImageFront` | AI-generated illustration (shown on front) |
| 8 | `ImageBack` | AI-generated illustration (shown on back) |
| 9 | `Sound` | Audio pronunciation (`[sound:file.mp3]`) |

## Installation via AnkiConnect

With [AnkiConnect](https://ankiweb.net/shared/info/2055492159) running, send `create-note-type.json` to create the note type automatically:

```bash
curl -X POST http://localhost:8765 \
  -H "Content-Type: application/json" \
  -d @create-note-type.json
```

## Manual Installation

1. Open Anki → **Tools → Manage Note Types → Add**
2. Choose **Add: Basic** as the base type
3. Name it `Vocabulary`
4. Add the fields listed above (in order) via **Fields...**
5. Edit the card template via **Cards...** and paste the HTML from `create-note-type.json`

## Migrating from "English" Note Type

If you have an existing "English" note type from a previous version:

1. In Anki: **Tools → Manage Note Types → select "English" → Rename → "Vocabulary"**
2. Add the `Sound` field: **Fields... → Add → "Sound"**
3. All existing cards, reviews, scheduling, and media are preserved — only the type name changes

Alternatively, keep using "English" — set `model = "English"` in your `configuration.lua` or change it in the on-device settings under **Anki Connection → Note type**.
