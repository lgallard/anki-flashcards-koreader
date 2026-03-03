---
description: "Test the card generation AI prompt with a sample phrase and show the result"
allowed-tools: ["Bash", "Read"]
---

# Test Card Generation Prompt

Tests the current AI prompt from `card_generator.lua` by sending a sample phrase to DashScope
and displaying the structured card JSON response.

**Usage:**
- `/test-prompt "eviction notice"` — test with phrase only
- `/test-prompt "eviction notice" "got an eviction notice from the landlord"` — with context
- `/test-prompt --dry-run "groove"` — show the rendered prompt without calling the API
- `/test-prompt "crank up" "he cranked up the volume" --title "The Great Gatsby" --author "F. Scott Fitzgerald"` — with book metadata

**Arguments:** `$ARGUMENTS` contains the phrase, optional context, and flags.

## Instructions for Claude

You MUST perform the following steps:

### 1. Parse arguments

- Extract the phrase (required, first quoted string or first argument)
- Extract context (optional, second quoted string)
- Check for `--dry-run` flag
- Extract `--title` and `--author` if provided (defaults: "Test Book", "Test Author")

### 2. Read the current prompt template

- Read `AnkiFlashcards.koplugin/card_generator.lua`
- Extract the `PROMPT_TEMPLATE` string (between `[[` and `]]`)
- This ensures the test always uses the latest prompt, not a stale copy

### 3. Render the prompt

- Substitute `{phrase}`, `{context}`, `{title}`, `{author}` into the template
- If no context provided, use the phrase itself as context: `{{{ <phrase> }}}`
- Display the rendered prompt to the user

### 4. Call DashScope API (unless --dry-run)

If `--dry-run` is set, stop after showing the rendered prompt.

Otherwise, read the API key from `AnkiFlashcards.koplugin/configuration.lua`:

```bash
# Extract API key from configuration.lua
API_KEY=$(grep -o "dashscope_api_key.*=.*\"[^\"]*\"" AnkiFlashcards.koplugin/configuration.lua | grep -o '"[^"]*"' | tail -1 | tr -d '"')
```

Then call the API:

```bash
curl -s https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{
    "model": "qwen-plus",
    "messages": [{"role": "user", "content": "<rendered_prompt>"}]
  }'
```

### 5. Parse and display the result

Extract the JSON card from the API response and display it formatted:

```
## Card Result

| Field        | Value                                           |
|--------------|--------------------------------------------------|
| Phrase       | <phrase>                                         |
| IPA          | <ipa>                                            |
| Definition   | <definition>                                     |
| Synonyms     | <synonyms>                                       |
| Cloze        | <text with {{c1::...}} highlighted>              |
| Image Prompt | <image_prompt>                                   |
```

### 6. Quality checks

After displaying the result, automatically check:
- Does the cloze `{{c1::...}}` wrap ONLY the phrase (no extra words)?
- Is the example sentence in a different scenario from the provided context?
- Is the definition within 20 words?
- Is the phrase in canonical form (lowercase, base/infinitive)?
- Are there 3-4 synonyms?

Report any issues found as warnings.
