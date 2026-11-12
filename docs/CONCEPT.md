# Margin: concept

> Working name. "Notes in the margin" of your design process.

## The problem

Documentation doesn't come naturally while you're designing. You're in flow,
moving fast in Figma, trying things, throwing things away. At the end you have a
polished final product and a short write-up of the big decisions, but the detail
is gone:

- the three layouts you tried before the one that shipped,
- *why* you picked a bottom sheet over a modal,
- the app or site that inspired the card style,
- the small trade-offs that a teammate (or future you) will ask about later.

Reconstructing that afterwards is slow, and it's mostly guesswork. The issue
isn't that people don't care about documentation. It's that documenting means
stopping what you're doing, switching tools, and writing prose.

## The idea

A tiny macOS menu bar app that makes documenting **as cheap as taking a
screenshot**, so it happens *during* the work instead of after it.

- Launch it from Spotlight (`⌘ Space` → "Margin"). An icon appears in the
  top-right menu bar and stays there.
- One click (or one shortcut) to capture what's on screen, log a decision, save
  some inspiration, or jot a note.
- Everything lands in a running, per-project **design log**, a timeline that
  tells the story of how the design got where it is.
- At the end, export the log to Markdown with images, ready to drop into a case
  study, a handoff doc, Notion, Confluence or a portfolio.

## Design principles

1. **Under five seconds.** Any capture should take less time than the thought
   it records. Minimal required fields; everything else optional.
2. **Context for free.** The app records what it can without asking: time,
   project, which app you were in (Figma, Sketch, a browser), a screenshot.
3. **Nudge, don't nag.** Gentle, optional reminders, only while you're actually
   in a design tool and haven't logged anything for a while. "What did you
   just decide?"
4. **Decisions are first-class.** A decision has a *what*, a *why* and *what
   else you considered*. That structure is what's missing from end-of-project
   write-ups.
5. **The output is a story.** The log reads chronologically, with a
   "decisions at a glance" summary up top.
6. **Your files, plain formats.** Stored as JSON + PNGs in `~/Library/Application Support/Margin/Archive`,
   exported as Markdown. No account, no lock-in.

## Core features (what the scaffold does today)

| Action | What happens |
| --- | --- |
| **Capture** (`⌘1`) | Crosshair region screenshot (like `⌘⇧4`), then a small window asks "What is this?" and "What's worth remembering?" |
| **Decision** (`⌘2`) | What you decided, why, and what else you considered. |
| **Inspiration** (`⌘3`) | Title, link (pre-filled if a URL is on your clipboard), what you like about it, optional pasted image. |
| **Note** (`⌘4`) | Free text, for anything else. |
| **Projects** | Every entry belongs to the current project; switch or create projects from the menu. |
| **Design log** | A timeline window grouped by day, filterable by type and searchable. |
| **Export** | Markdown file with a decisions summary, a day-by-day timeline and embedded images. |
| **Nudges** | Optional notification when you've been in a design app for a while with nothing logged. Click it to log a decision. |

## Ideas for later

- **Global hotkey** to capture from anywhere without opening the menu (e.g. via
  the `KeyboardShortcuts` Swift package).
- **Figma integration:** paste a Figma frame link and pull its thumbnail and
  name through the Figma API; link entries back to the exact frame.
- **Version diffs:** capture the same frame twice and show before/after side by
  side in the log.
- **Voice notes** transcribed into decision entries, for when typing is too
  much friction.
- **AI summary:** turn a project's log into a draft case study or a handoff
  summary ("here are the 12 decisions and their reasons").
- **Export targets:** Notion, Confluence, Google Docs, PDF.
- **Team mode:** a shared log per project.

## Who it's for

Product and UX designers, design students building portfolios and case studies,
and small teams who need handoff docs but don't have time to write them.

## Open questions for the team

- Name: "Margin" is a placeholder.
- How pushy should nudges be by default? (Currently: on, every 30 minutes, only
  while a design app is in front.)
- Is Markdown export enough for the competition demo, or do we want a nicer
  HTML/PDF "case study" view?
- Should captures automatically include the window title (e.g. the Figma file
  name)? That needs the Accessibility permission.
