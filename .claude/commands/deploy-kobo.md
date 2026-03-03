---
description: "Deploy the AnkiFlashcards plugin to a Kobo e-reader via USB (default) or SSH"
allowed-tools: ["Bash", "Read", "Glob"]
---

# Deploy AnkiFlashcards Plugin to Kobo

Deploys the `AnkiFlashcards.koplugin/` directory to a connected Kobo e-reader.
Excludes `configuration.lua` (credentials stay on device).

**Usage:**
- `/deploy-kobo` — deploy via USB mount (default)
- `/deploy-kobo --ssh 192.168.1.50` — deploy via SSH to the given IP
- `/deploy-kobo --ssh` — deploy via SSH (prompts for IP)

## Instructions for Claude

You MUST perform the following steps:

### 1. Parse arguments

- Check if `--ssh` flag is present in `$1` or `$2`
- If `--ssh` is followed by an IP address, use that IP
- If `--ssh` with no IP, ask the user for the Kobo's IP address
- Default (no flags): USB mount mode

### 2. Show what will be deployed

- Run `git status --short` in the repo to show what's changed
- Run `git log --oneline -3` to show recent commits
- List the files that will be copied from `AnkiFlashcards.koplugin/`

### 3. Deploy via USB (default)

- Check if `/Volumes/KOBOeReader` exists (Kobo mounted via USB on macOS)
- If not found, check `/Volumes/Kobo*` as fallback
- If mount not found, inform user: "Kobo not detected. Connect via USB or use --ssh"
- Target: `<MOUNT>/.adds/koreader/plugins/AnkiFlashcards.koplugin/`
- Verify the `.adds/koreader/plugins/` directory exists on the device
- Copy using `rsync -av --exclude='configuration.lua'` from `AnkiFlashcards.koplugin/` to target
- Show files copied and total size

### 4. Deploy via SSH (--ssh flag)

- Target: `root@<IP>:/mnt/onboard/.adds/koreader/plugins/AnkiFlashcards.koplugin/`
- Use `rsync -avz --exclude='configuration.lua' -e ssh` for efficient transfer
- If rsync not available over SSH, fall back to `scp -r` (excluding config manually)
- Show files transferred

### 5. Post-deploy

- Confirm successful deployment
- Remind user: "Restart KOReader on the Kobo to load the updated plugin"
- If any errors occurred, show them clearly
