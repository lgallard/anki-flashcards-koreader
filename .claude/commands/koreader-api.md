---
description: "Research KOReader Lua APIs by searching the koreader/koreader GitHub repository"
allowed-tools: ["Bash", "WebFetch", "WebSearch", "Read"]
---

# Research KOReader API

Searches the `koreader/koreader` GitHub repository for specific Lua modules, methods, or patterns.
Returns method signatures, arguments, and usage examples from KOReader's source code.

**Usage:**
- `/koreader-api saveHighlight` — find the saveHighlight method
- `/koreader-api "addToHighlightDialog"` — find highlight dialog registration API
- `/koreader-api UIManager` — explore the UIManager module
- `/koreader-api "NetworkMgr events"` — find network event hooks

**Argument:** `$ARGUMENTS` contains the API method, module, or search term.

## Instructions for Claude

You MUST perform the following research steps:

### 1. Parse the search query

- The user's search term is in `$ARGUMENTS`
- Identify whether it's a method name, module name, or general concept

### 2. Search KOReader source on GitHub

Use `gh` CLI to search the koreader/koreader repository:

```bash
# Search for code matches
gh api search/code -X GET -f "q=<QUERY>+repo:koreader/koreader+language:lua" --jq '.items[] | "\(.path):\(.name)"' | head -20
```

Also try targeted file searches for common KOReader modules:
- `frontend/apps/reader/modules/readerhighlight.lua` — highlight/selection API
- `frontend/ui/uimanager.lua` — UI lifecycle, scheduling
- `frontend/ui/network/manager.lua` — network/WiFi management
- `frontend/apps/reader/modules/readerannotation.lua` — annotations/bookmarks
- `frontend/ui/widget/` — all widget implementations
- `frontend/device/` — device capabilities

### 3. Fetch relevant source code

- Use `WebFetch` on the raw GitHub URL to read the actual source file
- URL pattern: `https://raw.githubusercontent.com/koreader/koreader/master/<path>`
- Search within the fetched content for the specific method/pattern
- Extract the function signature, arguments, and surrounding context (doc comments, usage)

### 4. Find usage examples

- Search for how the method is called in other parts of KOReader or in plugins:
```bash
gh api search/code -X GET -f "q=<METHOD_NAME>+repo:koreader/koreader+language:lua" --jq '.items[] | "\(.path)"' | head -10
```
- Look in `plugins/` directory for real plugin usage patterns

### 5. Present findings

Format the results clearly:

```
## Method: <name>
**File:** <path in koreader repo>
**Line:** <approximate line number>

### Signature
function Module:method(arg1, arg2)

### Arguments
- arg1 (type) — description
- arg2 (type, optional) — description

### Returns
- description of return value

### Example Usage (from KOReader source)
<code snippet showing how it's used>

### Notes
- Any caveats, version changes, or related methods
```

### 6. Suggest related APIs

- If relevant, mention related methods the user might also need
- Link to the GitHub source file for further reading
