# Margin

Margin is a Mac app that keeps a record of your design process while you work.
One shortcut captures whatever you're looking at (a Figma frame, selected text,
a website, a screen area or a short recording) and lets you add one line about
*why*. Everything lands in an archive you can browse from close-up (each day)
to big picture (the whole project).

## What you need

- A Mac with **macOS 13 Ventura or later** (Apple silicon or Intel).
- **Your own API keys** for the AI features (see below). Margin works without
  them, but captures won't get AI notes, headlines or themes.

## Install

1. Open `Margin.dmg` and drag **Margin** onto **Applications**.
2. Open Margin from Applications.

Margin isn't notarized by Apple, so the first time you open it macOS says it
can't verify the app. To open it anyway:

- **macOS 15 Sequoia or later:** click **Done**, then go to
  **System Settings → Privacy & Security**, scroll down, and click
  **Open Anyway** next to Margin. Confirm with your password.
- **macOS 13–14:** right-click (or Control-click) Margin in Applications,
  choose **Open**, then click **Open** again.

If macOS says Margin "is damaged and can't be opened", run this once in
Terminal, then open Margin again:

```bash
xattr -cr /Applications/Margin.app
```

## First run

Margin walks you through a short welcome. It needs two permissions:

1. **Screen Recording**, so it can capture the screen.
   System Settings → Privacy & Security → Screen & System Audio Recording → turn
   Margin on, then quit and reopen Margin.
2. **Accessibility**, for the double-tap shortcut, Figma links and selected
   text. System Settings → Privacy & Security → Accessibility → turn Margin on.

Margin lives in the menu bar (the bracket-and-dot icon).

## Using it

- **Capture:** double-tap either **⌘** key, or press **⌘⇧M**.
  - In Figma with a frame selected: saves a clean export of the frame.
  - With text selected (including Google Docs): saves the text.
  - With a link or address bar selected: saves the website.
  - Otherwise: drag an area or click a window to capture it, or switch to
    **Record** for a short recording.
- A card drops in under the menu bar: type one line about why and press
  **Return**, or press **Esc** to keep just the capture.
- **Archive:** open it from the menu bar icon. Drag the slider at the top from
  **close-up** to **big picture**.

### Figma (optional)

For exports of several frames at once and for animated frames, install
Margin's small Figma plugin: in Margin's **Settings**, click
**Margin plugin for Figma**. Then in the Figma desktop app choose
**Plugins → Development → Import plugin from manifest…** and pick the
`manifest.json` that Margin shows you. Run it once in each file you capture
from (**Plugins → Development → Margin**); it stays hidden.

## AI features: bring your own API keys

The downloaded Margin contains **no API keys**. To turn on the AI features, add
your own:

| Key | Used for | Where to get it |
| --- | --- | --- |
| **Gemini** (needed for AI) | Notes on each capture, headlines and summaries in the archive, themes | [Google AI Studio](https://aistudio.google.com/apikey) |
| **OpenAI** (optional) | Picking out decisions | [OpenAI API keys](https://platform.openai.com/api-keys) |

**To add them:**

1. Open Terminal and run:

   ```bash
   mkdir -p ~/.margin && cp "/Volumes/Margin/ai-keys.example.json" ~/.margin/ai-keys.json && open -e ~/.margin/ai-keys.json
   ```

   (If the disk image is no longer open, create `~/.margin/ai-keys.json`
   yourself with the contents of `ai-keys.example.json`.)
2. In the file that opens, paste your keys between the quotes:

   ```json
   {
     "gemini": "your-gemini-key",
     "openai": "your-openai-key"
   }
   ```

3. Save, then quit and reopen Margin. **Settings** shows whether the AI is on.

Your keys stay on your Mac in `~/.margin/ai-keys.json`. Margin sends captures to
Gemini (and OpenAI, if you added that key) only to describe and organise them.
Leave a key empty to keep that part off.

## Where your work is kept

Everything stays on your Mac, in `~/Library/Application Support/Margin/`. A log of what Margin
did is in `~/Library/Logs/Margin/margin.log`.

## Uninstall

Quit Margin from its menu, then delete Margin from Applications. To remove
your archive and keys too, delete `~/Library/Application Support/Margin/` and `~/.margin/`.
