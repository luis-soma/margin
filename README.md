# Margin

Document your design process while you work.

Margin is a Mac app for designers. Double-tap ⌘ to capture what you're
looking at (a Figma frame, a website, a selection, a screen area or a short
recording) and add one line about why. Everything lands in an archive you can
read from close-up to big picture, and hand off to your coding agent, a
review or a case study.

## Install

Tell your coding agent:

> Install Margin by following https://raw.githubusercontent.com/luis-soma/margin/main/INSTALL.md

Or download [Margin.dmg](https://github.com/luis-soma/margin/releases/latest/download/Margin.dmg),
drag Margin to Applications and open it. Margin isn't notarized: the first time,
macOS asks you to allow it in System Settings → Privacy & Security
(details in the [Read Me](Resources/Release/README.md)).

Needs macOS 13 or later.

## What it does

- **Capture.** One gesture for everything: double-tap ⌘. Margin works out what
  you're looking at and saves it with its source, like the frame's Figma link.
- **Add the why.** A small card asks for one line, typed or spoken. Esc keeps
  just the capture.
- **Documenting.** Reminder or Automatic: Margin asks after a quiet stretch,
  or keeps a capture whenever your design moves on.
- **Archive.** A timeline you zoom from each step to the whole project, and
  Themes, where Margin suggests groups and you decide what they mean.
- **Hand off.** The project as a folder your agent can read: the story by
  day, your decisions, the project's look and every capture. Everything, or
  only what's new since last time.

Your archive stays on your Mac, in `~/Library/Application Support/Margin`.
AI features are optional and use your own Gemini key.

## Build from source

Needs Xcode 16 or later.

```bash
scripts/build-app.sh --install     # build, copy to /Applications, open
swift test                         # tests
scripts/package-release.sh         # dist/Margin.dmg, as released
```

Releases are built by GitHub Actions (`.github/workflows/release.yml`) on a
Mac runner and attached to the [releases page](https://github.com/luis-soma/margin/releases).

## Credits

Designed and built by Luis Somasundaram, Edna Ho and Sarah Kwakkelaar.
Winner of the SVSD Design Competition 2026.

Fonts: Mona Sans and Geist Mono, both under the SIL Open Font License
(see `Resources/Fonts`).
