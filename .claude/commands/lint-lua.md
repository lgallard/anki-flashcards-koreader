---
description: "Validate Lua syntax and check for common issues in the plugin code"
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
---

# Lint Lua Plugin Code

Validates Lua syntax and checks for common issues across all plugin `.lua` files.

**Usage:**
- `/lint-lua` — check all files in `AnkiFlashcards.koplugin/`
- `/lint-lua card_viewer.lua` — check a specific file
- `/lint-lua --install` — install luacheck via Homebrew

**Argument:** `$ARGUMENTS` contains optional filename or `--install` flag.

## Instructions for Claude

You MUST perform the following steps:

### 1. Parse arguments

- If `$ARGUMENTS` contains `--install`, install luacheck: `brew install luacheck`
- If `$ARGUMENTS` contains a filename, lint only that file
- Default: lint all `.lua` files in `AnkiFlashcards.koplugin/`

### 2. Determine available tools

Check what's installed:
```bash
which luac 2>/dev/null && echo "luac: available" || echo "luac: not found"
which luacheck 2>/dev/null && echo "luacheck: available" || echo "luacheck: not found"
```

### 3. Syntax check with luac (if available)

Run `luac -p` on each target file to catch syntax errors:
```bash
for f in AnkiFlashcards.koplugin/*.lua; do
    luac -p "$f" 2>&1 && echo "OK: $f" || echo "FAIL: $f"
done
```

### 4. Lint with luacheck (if available)

Run luacheck with KOReader globals whitelisted:
```bash
luacheck AnkiFlashcards.koplugin/ \
    --std lua51 \
    --globals require \
    --read-globals Device Screen UIManager NetworkMgr \
    --no-unused-args \
    --no-max-line-length
```

### 5. Manual checks (always run, regardless of tools)

Even without luac/luacheck, perform these checks using Grep and Read:

**a) Require consistency** — verify all `require()` calls reference valid modules:
```bash
grep -n 'require(' AnkiFlashcards.koplugin/*.lua
```
Check that internal requires (card_storage, card_viewer, etc.) match actual filenames.

**b) Accidental configuration.lua require** — this file is gitignored and must only be loaded via pcall:
```bash
grep -rn 'require.*configuration' AnkiFlashcards.koplugin/*.lua
```
Flag any direct `require("configuration")` that isn't wrapped in `pcall`.

**c) Common Lua pitfalls:**
- Missing `local` on variables (globals leak across modules)
- Using `=` instead of `==` in conditions
- Missing `end` keywords (mismatched blocks)
- String concatenation with `+` instead of `..`

**d) UI safety:**
- Check for `UIManager:close(v)` where `v` might be stale (captured in closure but replaced by `update()`)
- Check for missing `UIManager:close()` before `UIManager:show()` (widget leaks)

### 6. Report results

Format the output as:

```
## Lint Results

### Syntax Errors
- (none) or list of errors with file:line

### Warnings
- (none) or list of potential issues

### Summary
- Files checked: N
- Errors: N
- Warnings: N
- Status: PASS / FAIL
```

If neither luac nor luacheck is installed, note this and suggest:
```
Neither luac nor luacheck found. Install with:
  brew install lua       # for luac
  brew install luacheck  # for luacheck
Manual checks were still performed.
```
