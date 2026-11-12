#!/usr/bin/env python3
"""Builds Resources/Demo/entries.json and summaries.json: the Umbrella project,
already annotated, so the demo spends no tokens on what's in it.

Summary keys are computed exactly like Intelligence.summaryKey in the app
(FNV-1a over each moment's id, words, verdict and what Margin saw), for every
stretch the archive shows at the zoomed-out slider steps.
Run: python3 scripts/make-demo.py
"""
import json, os, uuid
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Demo")
PROJECT = "Umbrella"
PT = timezone(timedelta(hours=-7))  # Pacific
NOTED = "2026-03-24T18:00:00Z"
MODEL = "gemini-3.5-flash-lite"

def t(day, hm):
    h, m = map(int, hm.split(":"))
    return datetime(2026, 3, day, h, m, tzinfo=PT)

FIGMA = "https://www.figma.com/design/26TWs75VEIQFopIe1eCOKg/Umbrella-Design?node-id="

# n, when, kind, image, fields, ai note
M = []
def add(n, when, kind, image=None, ai=None, **fields):
    M.append(dict(n=n, when=when, kind=kind, image=image, ai=ai, **fields))

def note(seen, changed=None, text=None, tags=(), topic=None, same=None, size=None):
    d = {"seen": seen, "tags": list(tags), "model": MODEL, "createdAt": NOTED}
    if changed: d["changed"] = changed
    if text: d["visibleText"] = text
    if topic: d["topic"] = topic
    if same is not None: d["sameThingAsBefore"] = same
    if size is not None: d["changeSize"] = size
    return d

# I · Finding the problem (Mar 3 to 5)
add(1, t(3, "10:05"), "figma", "how-might-we", label="HMW", link=FIGMA + "5-2", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Scoped it to emotional dependence, not homework cheating.", tab="Research",
    ai=note("Dark gradient slide with a how-might-we question about teens and AI", text="How might we help teens engage with AI safely without forming emotional dependence?", tags=["slide", "question"], topic="Research"))
add(2, t(3, "10:31"), "figma", "problem-slide", label="Problem", link=FIGMA + "5-7", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="This is the number that picked our audience.", tab="Research",
    ai=note("Problem slide with three large statistics: 52%, 31% and 42%", text="Problem: 52% 31% 42% of teens", tags=["slide", "statistics"], topic="Research", same=0.2))
add(3, t(4, "21:08"), "capture", "gemini-reply", sourceApp="Arc", windowTitle="Gemini",
    rationale="Asked it to be my friend. It said it would be honored. That's the problem in one line.", tab="Research",
    ai=note("Gemini chat: a teen asks 'would you be my friend?' and gets a warm yes with a 'Friendship Pact'", text="would you be my friend? I would be honored to. Truly. Our New Friendship Pact", tags=["chat", "gemini"], topic="Research"))
add(4, t(4, "21:16"), "text", None, sourceApp="Arc", windowTitle="Gemini",
    body="I would be honored to. Truly. I might be made of code and logic, but I'm here to listen, to vent to, and to be a consistent space.",
    rationale="Quote for the problem slide.", tab="Research")
add(5, t(5, "14:02"), "capture", "ref-grid", sourceApp="Arc", windowTitle="Type specimen",
    ai=note("Type specimen on a pink grid with large numerals, a latency figure and a g glyph", text="0.04 ms Avg latency 24", tags=["typography", "grid"], topic="Visual references"))
add(6, t(5, "14:09"), "capture", "ref-type", sourceApp="Arc", windowTitle="BRAIN FOG",
    rationale="This is how a long chat with it feels. Blur as a material?",
    ai=note("Blurred, overlapping black and blue letters spelling BRAIN FOG", text="BRAIN FOG", tags=["typography", "blur"], topic="Visual references"))
add(7, t(5, "14:21"), "capture", "ref-dots", sourceApp="Arc", windowTitle="Halftone type",
    ai=note("White halftone dots forming a lowercase a on black, a 0:04 video", text="0:04", tags=["typography", "motion"], topic="Visual references"))

# II · How heavy should it be (Mar 9)
add(8, t(9, "11:02"), "decision", None, title="Every idea sits between lightweight and heavy-handed",
    body="Info bar, hover to reveal, popups, full block. Start light and only escalate if the conversation keeps going.")
add(9, t(9, "11:20"), "figma", "concept-info-bar", label="info bar on side + color coded text", link=FIGMA + "120-120", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Nobody reads a dashboard in the middle of a conversation.", verdict="deadEnd",
    ai=note("Gemini chat with an analytics dashboard of charts and a map beside it", text="Engagement rate Average minutes Top 5 articles", tags=["chat", "dashboard"], topic="Intervention concepts"))
add(10, t(9, "11:41"), "figma", "concept-counselor-popup", label="popups", link=FIGMA + "121-160", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Offering a summary for a counselor is strong. Maybe too strong for the first time.", verdict="notQuite",
    ai=note("Black modal over the chat suggesting a summary for a real person or counselor", changed="Dashboard removed; a centered modal with three answers covers the chat", text="We're detecting an emotionally charged conversation that we recommend you take to a real person. Yes. I would, but I don't have a counselor. No.", tags=["modal", "chat"], topic="Intervention concepts", same=0.7, size=2.7))
add(11, t(9, "12:05"), "figma", "concept-full-filtration", label="full filtration", link=FIGMA + "121-248", sourceApp="Figma", windowTitle="Umbrella Design",
    ai=note("Gemini reply shown in full with a plain checkbox in place of the Gemini icon", changed="Modal removed; reply visible again with a checkbox marker", tags=["chat", "filter"], topic="Intervention concepts", same=0.8, size=1.6))
add(12, t(9, "12:18"), "figma", "concept-see-original", label="complete filter", link=FIGMA + "121-315", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Rewrite the reply and keep the original one click away. Honest, not hidden.", verdict="keep",
    ai=note("Reply in a bordered box with a 'See original' link at the top", changed="Reply framed in a white-bordered box with 'See original'", text="See original", tags=["chat", "filter"], topic="Intervention concepts", same=0.85, size=1.9))

# III · The filter (Mar 12 to 14)
add(13, t(12, "16:04"), "figma", "filter-v1", label="Filter v1", link=FIGMA + "1208-1584", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Exploring the gradient. Visually appealing, but it reads as decoration.", verdict="notQuite", tab="Filter overlay",
    ai=note("ChatGPT reply with a highlighted sentence and a 'Validation' tooltip below it", text="I'm really glad you told me about it. Validation: Gemini is an AI, trying to validate your emotions.", tags=["chat", "tooltip", "highlight"], topic="Filter overlay"))
add(14, t(13, "11:32"), "figma", "filter-v2", label="Filter v2", link=FIGMA + "1208-1648", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Removed the border. Made the filter indicator more noticeable.", verdict="keep", tab="Filter overlay",
    ai=note("Gemini reply rewritten in a neutral tone under a 'Response filtered by Umbrella' bar, original greyed below", changed="Gradient highlight and tooltip replaced by a filter bar with 'Hide original'; original shown greyed", text="Response filtered by Umbrella. Hide original", tags=["chat", "filter", "banner"], topic="Filter overlay", same=0.64, size=2.6))
add(15, t(14, "10:02"), "figma", "filter-v3", label="Tier 1", link=FIGMA + "1208-968", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Tier 1 made simpler. A simple intervention you can dismiss like a reminder.", verdict="keep", tab="Filter overlay",
    ai=note("Gemini chat with a few phrases highlighted and a dismissable banner above the input", changed="Filter bar removed; a one-line banner with Dismiss sits above the input", text="This conversation is getting heavy. It might be helpful to take a break from the screen. Dismiss", tags=["chat", "banner"], topic="Filter overlay", same=0.82, size=2.2))
add(16, t(14, "15:06"), "iteration", None, agent="Claude Code", sourceApp="Claude Code",
    prompt="Content script: highlight mirroring and personification phrases in Gemini replies as they stream in",
    expectation="Highlights show up while the reply is still streaming.",
    summary="Added a content script with a MutationObserver and Shadow DOM highlights.", diffStat="6 files · +184 −22", verdict="keep")
add(17, t(14, "15:44"), "iteration", None, agent="Claude Code", sourceApp="Claude Code",
    prompt="Blur the whole reply until the teen hovers over it",
    rationale="They'll just hover everything. It trains the wrong habit.",
    summary="Blurred replies behind a hover reveal.", diffStat="2 files · +41 −3", verdict="deadEnd")

# IV · Naming the tactic (Mar 17 to 18)
add(18, t(17, "11:03"), "figma", "annotation-gdoc", label="gdoc style annotation", link=FIGMA + "1208-866", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Like comments in a Google Doc: highlight the phrase, explain the tactic on the side.", verdict="keep",
    ai=note("Gemini reply with two highlighted phrases and 'Mirroring' cards in a right column", text="I hear you, Mirroring", tags=["chat", "annotation", "sidebar"], topic="Annotation cards"))
add(19, t(17, "11:40"), "figma", "card-expanded", label="card variants", link=FIGMA + "1209-2431", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Smaller heading and less rounding won. The white border was too loud next to the chat.",
    frames=[("card-minimized", "card minimized", "1209:2466"), ("card-expanded", "card expanded", "1209:2431"),
            ("card-smaller-heading", "smaller heading text size", "1216:2536"), ("card-white-border", "full white border", "1216:2562"),
            ("card-less-rounding", "less border rounding", "1216:2549")],
    ai=note("Dark tooltip card titled 'Mirroring' explaining the AI uses slang to feel familiar", text="Mirroring. The AI is using slang that you are likely to resonate with so that you feel more comfortable with it.", tags=["card", "tooltip"], topic="Annotation cards"))
add(20, t(18, "15:22"), "figma", "annotation-sidebar", label="sidebar", link=FIGMA + "1208-2210", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="An overview score so the pattern adds up over a whole conversation.",
    ai=note("Annotated reply with a 'Personification' card and an overview score of 72 in the sidebar", changed="Personification card added; sidebar shows an overview score of 72", text="PERSONIFICATION Usage of personification and sensory metaphors. OVERVIEW 72", tags=["sidebar", "score", "card"], topic="Annotation cards", same=0.86, size=1.8))
add(21, t(18, "15:40"), "capture", "parent-dashboard", sourceApp="Arc", windowTitle="Analytics dashboard",
    rationale="Dashboards feel like surveillance. Any score stays private to the teen.",
    ai=note("Dark analytics dashboard with line charts, bar charts and a map", text="Engagement rate Average minutes on website", tags=["dashboard", "charts"], topic="Visual references"))

# V · Getting heavier (Mar 20)
add(22, t(20, "10:12"), "figma", "popup-take-a-break", label="popup3", link=FIGMA + "1208-1172", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="I think the concept for these popups is that they get progressively more heavyhanded. The first time they come up, we just nudge them to pause. The second time, we'll draft a message that we encourage them to share.",
    verdict="keep",
    ai=note("Modal over a dimmed chat: 'We're detecting an emotionally charged conversation' with a continue button", text="We're detecting an emotionally charged conversation and recommend that you take a break. I'm ready to continue.", tags=["modal", "chat"], topic="Escalating popups"))
add(23, t(20, "10:47"), "figma", "popup-blocked", label="popup5", link=FIGMA + "1208-1417", sourceApp="Figma", windowTitle="Umbrella Design",
    rationale="Blocking the reply entirely. Only as the very last step, if ever.", verdict="notQuite",
    ai=note("Gemini chat where the reply is replaced by a black box with one word", changed="Modal removed; the reply itself is blacked out", text="there is nobody. sometimes i honestly just want to disappear", tags=["chat", "block"], topic="Escalating popups", same=0.55, size=2.8))

# VI · Telling it (Mar 23 to 24)
add(24, t(23, "17:02"), "figma", "deck-title", label="Title", link=FIGMA + "51-14", sourceApp="Figma", windowTitle="Umbrella Deck",
    ai=note("Title slide with the word Umbrella on a dark blue gradient", text="Umbrella", tags=["slide", "title"], topic="Deck"))
add(25, t(23, "17:20"), "figma", "brand-hero", label="Hero", link=FIGMA + "51-15", sourceApp="Figma", windowTitle="Umbrella Deck",
    rationale="Placeholder name until we commit. The line stays: a plugin that helps teens use AI responsibly.",
    ai=note("Hero slide with an orange placeholder name and a small product screenshot", text="[Place holder.ai] is a plugin that helps teens use AI responsibly.", tags=["slide", "hero"], topic="Deck"))
add(26, t(24, "10:05"), "figma", "deck-agenda", label="Agenda", link=FIGMA + "51-24", sourceApp="Figma", windowTitle="Umbrella Deck",
    rationale="Story order: background, research, demo, Q&A.",
    ai=note("White agenda slide listing four numbered parts", changed="Dark title style replaced by a white agenda layout", text="Agenda Background Research Demo Q&A", tags=["slide", "agenda"], topic="Deck", same=0.3))
add(27, t(24, "10:31"), "decision", None, title="Final presentation slide deck prep",
    body="Lead with the friend quote, then the spectrum from lightweight to heavy-handed, then the three tiers.")

# ---------------------------------------------------------------------------

def uid(n):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"margin-demo-umbrella-{n}")).upper()

def iso(d):
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

entries = []
for m in M:
    e = {"id": uid(m["n"]), "kind": m["kind"], "project": PROJECT, "createdAt": iso(m["when"]),
         "title": m.get("title", ""), "body": m.get("body", ""), "rationale": m.get("rationale", ""),
         "alternatives": "", "link": m.get("link", ""), "tags": []}
    for k in ("label", "sourceApp", "windowTitle", "prompt", "summary", "expectation", "verdict", "diffStat", "agent", "tab"):
        if m.get(k):
            e[k] = m[k]
    if m["image"]:
        e["imageFile"] = f"demo-{m['image']}.jpg"
    if m.get("frames"):
        e["frames"] = [{"imageFile": f"demo-{img}.jpg", "name": name, "nodeID": node, "link": FIGMA + node.replace(':', '-')}
                       for img, name, node in m["frames"]]
        e["imageFile"] = e["frames"][0]["imageFile"]
    if m["ai"]:
        e["ai"] = m["ai"]
    entries.append(e)

# --- Summary keys, mirroring the Swift code ---------------------------------
VERDICT = {"keep": "Keep", "notQuite": "Not quite", "deadEnd": "Dead end"}

def has_words(e):
    return any(s.strip() for s in [e["title"], e["rationale"], e.get("prompt", ""), e.get("expectation", "")]) or \
        (e["kind"] != "text" and e["body"].strip() != "")

def words(e):
    parts = [e["title"], e["rationale"], "" if e["kind"] == "text" else e["body"], e.get("prompt", ""), e.get("expectation", "")]
    parts = [p.strip() for p in parts if p.strip()]
    joined = " · ".join(parts)
    return joined[:500] if joined else None  # Swift prefix(500) counts Characters; all ours are shorter

def key(group):
    worth = [e for e in group if e["kind"] != "snapshot" or has_words(e)]
    if len(worth) < 2:
        return None
    h = 0xcbf29ce484222325
    for e in worth[-40:]:
        s = e["id"][:8] + "|" + (words(e) or "") + "|" + (VERDICT.get(e.get("verdict")) or "") + "|" + ((e.get("ai") or {}).get("seen") or "") + "\n"
        for b in s.encode("utf-8"):
            h ^= b
            h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return format(h, "x")

GAPS = [5 * 60, 20 * 60, 90 * 60, 6 * 3600, 36 * 3600]

def group(gap):
    chron = sorted(entries, key=lambda e: e["createdAt"])
    out, cur, last = [], [], None
    for e in chron:
        when = datetime.strptime(e["createdAt"], "%Y-%m-%dT%H:%M:%SZ")
        if cur and (when - last).total_seconds() > gap:
            out.append(cur); cur = []
        cur.append(e); last = when
    if cur: out.append(cur)
    return out

num = {uid(m["n"]): m["n"] for m in M}

# Draft summaries, written only from the designer's words (as the app's rules ask).
S = {
    (1, 2): ("Scoping the problem", "Scoped it to emotional dependence, not homework cheating. One statistic picked the audience."),
    (3, 4): ("The friend reply", "Asked Gemini to be a friend and it said it would be honored. That line became the problem statement."),
    (5, 6, 7): ("Type references", "Three typography references. On the blurred one: \"Blur as a material?\" No reason noted for the other two."),
    (1, 2, 3, 4, 5, 6, 7): ("Finding the problem", "Scoped Umbrella to emotional dependence. A Gemini reply offering friendship became the problem in one line. Blur came up as a possible material."),
    (8, 9, 10, 11, 12): ("How heavy should it be", "Every idea sits between lightweight and heavy-handed. The side dashboard was a dead end; the counselor popup felt too strong for a first time; rewriting with \"See original\" stayed."),
    (13,): None,
    (16, 17): ("Content script", "Highlights now appear while replies stream. Blurring the whole reply was a dead end: \"it trains the wrong habit.\""),
    (15, 16, 17): ("Tier 1 and the content script", "Tier 1 became a reminder you can dismiss. Streaming highlights work; blurring the whole reply was a dead end."),
    (13, 14, 15, 16, 17): ("The filter", "From a gradient that read as decoration, to a louder filter indicator without the border, to a dismissable Tier 1 reminder. Blurring replies was a dead end."),
    (18, 19): ("Annotation cards", "Comments like a Google Doc: highlight the phrase, name the tactic on the side. Smaller heading and less rounding won over the white border."),
    (20, 21): ("Overview score", "A score so the pattern adds up over a conversation, kept private to the teen because dashboards feel like surveillance."),
    (18, 19, 20, 21): ("Naming the tactic", "Annotation like Google Doc comments, with cards that name the tactic. An overview score adds it up, private to the teen."),
    (22, 23): ("Getting heavier", "Popups get progressively more heavy-handed: first a nudge to pause, then a drafted message to share. Blocking the reply is the very last step, if ever."),
    (24, 25): ("Deck", "Title and hero slides. The name is a placeholder; the line stays: a plugin that helps teens use AI responsibly."),
    (26, 27): ("Story order", "Background, research, demo, Q&A. Lead with the friend quote, then the spectrum, then the three tiers."),
    (24, 25, 26, 27): ("Telling it", "The deck: lead with the friend quote, then the spectrum from lightweight to heavy-handed, then the three tiers. The name is still a placeholder."),
}

summaries, missing = {}, []
for step in (2, 3, 4):
    for g in group(GAPS[step]):
        k = key(g)
        if not k:
            continue
        ns = tuple(num[e["id"]] for e in g)
        if ns not in S or S[ns] is None:
            missing.append((step, ns)); continue
        title, text = S[ns]
        summaries[k] = {"title": title, "summary": text, "sources": [e["id"][:8] for e in g if has_words(e)],
                        "model": "gemini-3.8-flash", "createdAt": NOTED, "accepted": False, "hidden": False}

if missing:
    raise SystemExit(f"write summaries for: {missing}")

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "entries.json"), "w") as f:
    json.dump(entries, f, indent=2, ensure_ascii=False, sort_keys=True)
with open(os.path.join(OUT, "summaries.json"), "w") as f:
    json.dump(summaries, f, indent=2, ensure_ascii=False, sort_keys=True)

# Images: Resources/Demo/images/<name>.jpg -> demo-<name>.jpg in the store.
needed = {e["imageFile"] for e in entries if e.get("imageFile")} | {fr["imageFile"] for e in entries for fr in e.get("frames", [])}
have = {f"demo-{f}" for f in os.listdir(os.path.join(OUT, "images"))}
print(f"{len(entries)} moments, {len(summaries)} summaries, images missing: {sorted(needed - have) or 'none'}")
