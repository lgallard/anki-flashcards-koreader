# Anki Note Type

This folder contains the **English** note type definition used by the AnkiFlashcards plugin.

## Fields

| Field | Description |
|-------|-------------|
| `Phrase` | Canonical form of the phrase (base/infinitive, lowercase) |
| `IPA` | American English IPA notation |
| `Definition` | Context-aware definition (up to 20 words) |
| `Synonyms` | 3–4 synonyms, comma-separated |
| `Text` | Cloze example sentence using `{{c1::...}}` |
| `Source` | Cambridge Dictionary URL for the phrase |
| `ImageFront` | AI-generated illustration (shown on front) |
| `ImageBack` | AI-generated illustration (shown on back) |

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
3. Name it `English`
4. Add the fields listed above (in order) via **Fields...**
5. Edit the card template via **Cards...** and paste the HTML from `create-note-type.json`
