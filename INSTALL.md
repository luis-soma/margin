# Install Margin (for your coding agent)

These are instructions for an agent such as Claude Code or Codex, installing
Margin on the user's Mac. A person can follow them too.

Margin is a free, open source Mac app (macOS 13 or later, Apple silicon or
Intel). It isn't notarized by Apple, which is why step 4 exists.

## Steps

1. Download the latest disk image:

   ```bash
   curl -L -o /tmp/Margin.dmg https://github.com/luis-soma/margin/releases/latest/download/Margin.dmg
   ```

2. Mount it and copy the app to Applications (replace an older copy if there
   is one; quit Margin first if it's running):

   ```bash
   osascript -e 'quit app "Margin"' 2>/dev/null || true
   hdiutil attach -nobrowse -quiet /tmp/Margin.dmg -mountpoint /tmp/margin-dmg
   rm -rf /Applications/Margin.app
   cp -R /tmp/margin-dmg/Margin.app /Applications/
   hdiutil detach -quiet /tmp/margin-dmg
   rm /tmp/Margin.dmg
   ```

3. Check it's there:

   ```bash
   ls /Applications/Margin.app
   ```

4. Margin isn't notarized, so clear the download flag macOS puts on it.
   Without this, macOS refuses to open it the first time:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Margin.app
   ```

5. Open it:

   ```bash
   open /Applications/Margin.app
   ```

## Then tell the user

- Margin opens with a short welcome. It asks for **Screen Recording** (to
  capture the screen) and **Accessibility** (for the shortcut and Figma
  links). Both are switched on in System Settings → Privacy & Security.
  After turning on Screen Recording, Margin needs a restart.
- To capture anything, **double-tap ⌘**. A card drops in under the menu bar:
  type one line about why, or press Esc to keep just the capture.
- The archive opens from the menu bar icon (a bracket with a dot).
- AI notes, headlines and themes are optional and use the user's own Gemini
  key, added at the end of the welcome or later in Settings → Intelligence.

## Build from source instead

Needs Xcode 16 or later.

```bash
git clone https://github.com/luis-soma/margin.git
cd margin
scripts/build-app.sh --install
```
