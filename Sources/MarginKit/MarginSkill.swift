import Foundation

/// The Claude skill that documents a project into Margin: the steps a
/// Claude chat follows with Margin's tools. Served by margin-mcp as a
/// prompt, and saved from Settings as a skill to add to Claude.
public enum MarginSkill {
    public static let name = "document-in-margin"
    public static let summary = "Use when asked to document a project, chat or design process in Margin: gathers chats, project files, artifacts and Figma frames and adds them to the Margin timeline by date."

    /// SKILL.md as Claude reads it.
    public static var markdown: String {
        "---\nname: \(name)\ndescription: \(summary)\n---\n\n" + body
    }

    public static let body = """
# Document this in Margin

Turn what you know about this work into a process archive in Margin: what was explored, made, referenced and decided, each at the time it happened, so the designer can see how the project got here.

This needs Margin's tools (`margin_projects`, `margin_project`, `margin_add`, `margin_about`). They come from Margin on the designer's Mac once it's connected (Margin › Settings › Claude app › Connect, then reopen Claude) and Margin is open. If the tools aren't there, say so in one line and stop: don't write the archive as a document instead.

## 1. Find the Margin project
- Use the project the designer named. If they didn't, call `margin_projects` and pick the one that matches this work; if none does, ask once, or use a short name for the work (a new project is made by adding to it).
- Call `margin_project` with that name to see what's already there. Don't add anything that's already in it.

## 2. Agree on the scope
- If the request already says what to document (this chat, one phase, a date range, a set of files, or "everything"), do exactly that.
- Otherwise ask once before gathering anything: the whole project (everything about it that isn't in Margin yet), or only part of it (this chat, a phase, a date range, certain files). Offer these as choices if you can show options.
- Whole project means every source you can reach for this work, minus what `margin_project` shows is already there.

## 3. Gather the material
Look through everything you can reach for this work:
- This chat, and when you're in a Claude project: the project's files and instructions, and its other chats (search past chats, open the relevant ones).
- Artifacts and documents made along the way, and links that came up.
- Figma: frames and files linked or discussed. With the Figma connector, list the important frames (with their node links).
- Dates: use when each thing actually happened (a chat's date, a file's date, a date mentioned). Don't put everything at today. If you only know the week or month, use its first day and say in the body that the date is approximate.

## 4. Choose what to keep
A good archive is selective. Keep what shows the process:
- Turning points and decisions (what was chosen, what was dropped, and why if the designer said so).
- Each meaningful version of a design or idea, not every small edit.
- References and inspiration that shaped the work.
- Research findings, feedback received, problems found.
Leave out small talk, repeated drafts and anything private that isn't about the work.

## 5. Add it
Call `margin_add` with up to 20 captures at a time, oldest first. For each:
- `kind`: `note` (a step, finding or idea), `decision`, `text` (an excerpt worth keeping as written), `link` (a website), `figma` (a Figma frame), `inspiration` (a reference), `image` (a picture with an address).
- `title`: short and specific, in plain words ("Narrowed the topic to repair cafés", not "Update").
- `body`: the annotation. A few sentences on what it was, what it changed and how it connects to what came before. Facts from the material, not praise.
- `tags`: one to three short topics (for example "research", "concept", "feedback"), the same words across the project.
- `when`: the date it happened (YYYY-MM-DD, or a full ISO time if known).
- `figma_url` for frames (with node-id), `link` for websites and documents, `image_url` for a picture you have a public address for.
- `why`: only the designer's own words for their reasoning, quoted from what they wrote. Never your interpretation. Leave it out otherwise.
- `alternatives` for decisions: what else was considered.
- `source`: where it came from ("Claude chat", "Figma", "Claude project file").

## 6. Update the project's About
`margin_project` shows the project's About text (`about`): what it is, who it's for, what the designer is trying to find out. Ask, the hand off and Claude read it.
- Empty: write one from the material with `margin_about`. Two or three short paragraphs: what the project is, who it's for, the question or goal, and where it stands now. Plain words, facts from the material.
- Already written: it's the designer's text. Keep their words, and only add what's clearly new (a changed goal, the current stage). Say what you changed. If nothing is new, leave it.

## 7. Report back
Say in two or three lines what you added (how many, over which dates), what you left out, anything that came in without a picture and whether you wrote or changed the About.
"""
}
