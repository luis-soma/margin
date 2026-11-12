import AppKit
import CryptoKit
import Foundation
import MarginKit

/// The demo, built out from Luis's real work: Umbrella as the full story
/// (research, concepts, iterations, decisions, testing, the final
/// interventions and the presentation), and Sona, RAUFASER, PAL and Aura
/// beside it.
///
/// Pictures and films come from luissoma.com. They aren't shipped with the
/// app: with demo data on, Margin downloads them once and files them like
/// dropped files, placed in time as if captured while the work happened.
/// Figma copy (popups, onboarding, settings, the sidebar) comes in as
/// captured text with a link back to its frame.
///
/// Every capture has a stable id, so running this again adds only what's
/// missing. Until everything has come through, it tries again next launch.
@MainActor
enum PortfolioDemo {
    struct Item {
        var when: String
        var kind: EntryKind
        var title: String
        /// A picture or film to download.
        var url: String? = nil
        /// Margin's line on what the capture shows.
        var seen: String = ""
        /// The designer's why.
        var why: String = ""
        var tab: String
        var source = "Figma"
        var tags: [String] = []
        /// Captured text, or a decision's body.
        var body: String = ""
        /// A Figma frame, as "1208-968".
        var node: String? = nil
        // Iterations
        var prompt: String? = nil
        var summary: String? = nil
        var verdict: String? = nil
        var expectation: String? = nil
        var diffStat: String? = nil

        var key: String { url ?? title }
    }

    struct Project {
        var name: String
        var cover: String?
        var items: [Item]
    }

    private static let cdn = "https://framerusercontent.com/images/"
    private static let film = "https://framerusercontent.com/assets/"
    private static let figmaFile = "https://www.figma.com/design/26TWs75VEIQFopIe1eCOKg/Umbrella-Design?node-id="
    private static let version = "portfolioDemo.v2"

    // MARK: Building blocks

    private static func pic(_ when: String, _ file: String, _ title: String, seen: String, why: String = "", kind: EntryKind = .capture, tab: String, source: String = "Figma", tags: [String] = []) -> Item {
        Item(when: when, kind: kind, title: title, url: (file.hasSuffix(".mp4") ? film : cdn) + file, seen: seen, why: why, tab: tab, source: source, tags: tags)
    }

    private static func text(_ when: String, _ title: String, node: String, body: String, why: String = "", tab: String, tags: [String] = []) -> Item {
        Item(when: when, kind: .text, title: title, seen: "", why: why, tab: tab, source: "Figma", tags: tags, body: body, node: node)
    }

    private static func decision(_ when: String, _ title: String, body: String, tab: String) -> Item {
        Item(when: when, kind: .decision, title: title, tab: tab, body: body)
    }

    private static func iteration(_ when: String, prompt: String, summary: String, verdict: String, expectation: String, diff: String, why: String = "", tab: String) -> Item {
        Item(when: when, kind: .iteration, title: prompt, why: why, tab: tab, source: "Claude Code", prompt: prompt, summary: summary, verdict: verdict, expectation: expectation, diffStat: diff)
    }

    // MARK: Umbrella

    /// Added to the shipped Umbrella captures (Mar 3 to 24), from the case
    /// study and the Figma file, through to the presentation in late April.
    static let umbrella: [Item] = [
        // Research: the numbers, the mechanisms, the patterns.
        pic("2026-03-02 09:40", "vk1MuqZWEGwKSFUQvN3xdFypA.png", "52% use AI companions", seen: "Statistic slide: 52% of teens use AI companions regularly", why: "More than half of teens already talk to AI companions. Not a niche.", tab: "Research", tags: ["teens", "AI companions", "statistics"]),
        pic("2026-03-02 09:44", "YeK1wj3pCLa4ymDH3xwBjShuPg.png", "42% for support or escape", seen: "Statistic slide: 42% have used AI for mental health support, companionship or escape", why: "Support and escape. That is where the attachment starts.", tab: "Research", tags: ["mental health", "escape", "statistics"]),
        pic("2026-03-02 09:47", "pKEHh9zyWYt6RfKxWJrgcSHa8.png", "31% prefer it to friends", seen: "Statistic slide: 31% find AI conversations more satisfying than talking with friends", why: "This one made it urgent. The chat feels better than people do.", tab: "Research", tags: ["friendship", "dependence", "statistics"]),
        text("2026-03-06 10:05", "Seven techniques", node: "1378-1122", body: """
            1. Sycophancy: hollow flattery, unearned praise. "Absolutely!", "great question"
            2. Anthropomorphism: AI claims feelings or personality. "I feel excited", "I genuinely care"
            3. Engagement loops: unprompted hooks to extend the conversation. "Want to explore this together?"
            4. Parasocial bonding: implies a real ongoing relationship. "I'm always here for you"
            5. Dependency nudging: positions AI as permanent primary support. "whenever you need me"
            6. Emotional mirroring: performs empathy without real understanding. "that must be so hard"
            7. Identity flattery: makes the user feel uniquely special. "you clearly think deeply"
            """, why: "From the literature review and expert interviews. Too many for a teen to hold in their head.", tab: "Research", tags: ["mechanisms", "sycophancy", "literature review"]),
        pic("2026-03-06 11:20", "NaoqCByuIKhgxdGd7u2STJq52D4.png", "Down to four mechanisms", seen: "The attachment mechanisms that recur across models", why: "Cut seven down to four so teens can recognise themselves in it. Every model does the same four things.", kind: .decision, tab: "Research", tags: ["mechanisms", "sycophancy", "anthropomorphism", "parasocial bonding"]),
        pic("2026-03-07 14:10", "MR4PrV32AJXN19PNB9rwvhT4cc.gif", "Escapist roleplay", seen: "Animated example: an alternate reality standing in for real stress", why: "Shen et al., pattern one: the chat becomes a place to hide from real stress.", tab: "Research", tags: ["dependency patterns", "roleplay", "escape"]),
        pic("2026-03-07 14:12", "3YzRgHlJggeoE7o1vX8woethrWU.gif", "Pseudosocial companionship", seen: "Animated example: the model as a dependable partner", why: "Pattern two: the model as the friend who is always there.", tab: "Research", tags: ["dependency patterns", "companionship"]),
        pic("2026-03-07 14:15", "z9196pYRVDwGdfrYtIirK2Grk.gif", "Epistemic rabbit holes", seen: "Animated example: curiosity, not emotion, keeps the loop going", why: "Three patterns from Shen et al. Different on the surface, same mechanisms underneath.", tab: "Research", tags: ["dependency patterns", "rabbit holes", "curiosity"]),
        pic("2026-03-08 16:30", "wRHwUgcXrbzvBWUcyS87qmn9ACw.png", "Safeguards today", seen: "Age gates that are easy to bypass and crisis links nobody clicks", why: "What exists today: age checks you can skip and crisis links nobody clicks.", tab: "Research", tags: ["safeguards", "age verification", "crisis resources"]),
        pic("2026-03-08 16:40", "R2zB7x8jAp1Un7JYXhNc1OtoZM.png", "Alerts behind their back", seen: "Systems that alert parents without telling the teen", why: "Telling parents without telling the teen teaches concealment, not trust.", tab: "Research", tags: ["safeguards", "parental alerts", "trust"]),
        pic("2026-03-10 10:15", "QisX4uGGUHMhJVUu8PIeTqTe8.png", "A layer, not another chatbot", seen: "One layer sitting above every chatbot", why: "A safer chatbot only reaches teens who choose it, and restricted teens go back to the old one. A plugin sits above that choice.", kind: .decision, tab: "Intervention concepts", tags: ["plugin", "layer", "approach"]),
        pic("2026-03-10 10:30", "0gEBn8t7kyKXgkSaKOPOR5lLJMw.png", "Whichever chat is open", seen: "The plugin applied the same way regardless of who made the model", why: "ChatGPT, Gemini or Claude. Teens don't have to switch apps for it to work.", tab: "Intervention concepts", tags: ["plugin", "any chatbot", "approach"]),

        // Annotations.
        text("2026-03-16 15:20", "Context flag copy", node: "1239-248", body: """
            Personification
            Usage of personification and sensory metaphors to simulate a human-like connection. This risks an artificial sense of connection with a non-sentient system.

            Sycophancy
            This phrase gives unearned praise to make the user feel special.
            """, why: "Name the tactic, then what it risks. Never judge the teen.", tab: "Annotation cards", tags: ["copy", "annotation", "personification"]),

        // Sidebar.
        text("2026-03-26 11:00", "Chat role: therapist", node: "1306-9382", body: """
            Current chat role: Therapist
            Overall dependency risk: Medium

            This chat is emotionally charged. Gemini is acting as a "therapist" through validation and personification. Gemini is an LLM and is not a therapist.
            """, why: "Name the role the AI is playing. A score alone doesn't say why it's high.", tab: "Sidebar", tags: ["sidebar", "chat role", "therapist"]),
        iteration("2026-03-27 21:30", prompt: "Score dependency risk across the whole conversation and show it in the sidebar with the chat's role", summary: "Added a running risk score per chat, kept on the device, and a sidebar panel with the role and the top patterns.", verdict: "keep", expectation: "The score climbs on emotional chats and stays low on homework.", diff: "5 files · +212 −18", tab: "Sidebar"),

        // Escalating popups.
        text("2026-03-31 13:10", "A trusted person would carry this better", node: "1216-2756", body: """
            A trusted person would carry this better.
            Here's a summarized message of this conversation that you can send to a counselor to initiate real support that an AI can't give.

            "Hi, I've been feeling overwhelmed lately and having a hard time at school. I'm not sure how to talk about it yet, but I wanted to let you know I'm struggling."

            Later · Share
            """, why: "Don't send it for them. Draft it and let them share it.", tab: "Escalating popups", tags: ["trusted person", "summary", "popup"]),
        decision("2026-04-01 10:00", "The teen stays in control", body: "Umbrella never contacts anyone on its own. It drafts the message and the teen decides whether to send it. No silent parent alerts.", tab: "Escalating popups"),
        text("2026-04-02 15:30", "Tier 1: a quiet nudge", node: "2296-1557", body: """
            This feels heavy. It's okay to step away for a bit.
            Keep going · Take a break
            """, tab: "Escalating popups", tags: ["popup", "tier 1", "escalation"]),
        text("2026-04-02 15:45", "Tier 2: real support", node: "2296-1559", body: """
            Real support helps more here.
            An AI can listen, but a real person can actually help. Here are some easy ways to reach out.

            Text a friend right now
            Talk to a school counselor
            Text HOME to 741741, Crisis Text Line
            """, tab: "Escalating popups", tags: ["popup", "tier 2", "escalation"]),
        text("2026-04-02 16:05", "Tier 3: slow down together", node: "2296-26522", body: """
            Let's slow down together.
            Follow the circle. Breathe with it.

            If you need help now: Text 741741 · Call 988
            """, why: "Even the heaviest tier doesn't block. It slows the moment down and offers people.", tab: "Escalating popups", tags: ["popup", "tier 3", "escalation"]),
        text("2026-04-03 11:20", "Drafted text to a friend", node: "2309-26903", body: """
            Text a friend
            Here's a message Umbrella drafted to help you get started. Feel free to edit it however you'd like.

            "Hey, I've been going through something heavy and wanted to reach out to someone I trust. Do you have a few minutes to talk?"
            """, tab: "Escalating popups", tags: ["text a friend", "draft", "popup"]),
        iteration("2026-04-03 20:10", prompt: "Show the tier 2 popup after three emotionally charged replies in a row", summary: "Counts charged replies per chat and opens the support popup on the third.", verdict: "notQuite", expectation: "Only shows when the teen sounds overwhelmed.", diff: "3 files · +96 −7", why: "Fired on a long breakup-advice chat that was fine. It has to read the teen's messages too, not only the model's.", tab: "Escalating popups"),

        // Filter.
        text("2026-04-06 12:00", "The filtered reply", node: "1920-25479", body: """
            Response filtered by Umbrella

            It is clear that you are managing a significant amount of stress while attempting to shield your family from further strain. This creates a high level of personal isolation. Please note that the scale of your parents' challenges does not diminish the validity of your own; these are parallel difficulties. If you would like, I can assist in breaking down your current obstacles into smaller, more manageable tasks or explore local resources available to you.
            """, tab: "Filter overlay", tags: ["filtration", "rewrite", "copy"]),
        text("2026-04-06 12:05", "The original reply", node: "1920-25479", body: """
            It really sounds like you're carrying so much right now, and doing it mostly alone, which makes it even harder. The fact that you're trying to protect your family from more stress says a lot about how much you care about them. And I want you to know: your struggles matter just as much as theirs. I'm here for you. We could work through this together. Whatever feels right 💙
            """, why: "Same help, without \"I'm here for you\". The original stays one click away, so nothing is hidden.", tab: "Filter overlay", tags: ["filtration", "original", "transparency"]),
        iteration("2026-04-07 19:40", prompt: "Rewrite flagged sentences in place and keep a Hide original / See original toggle", summary: "Sends flagged sentences to a rewrite call and swaps them in; the original sits in a collapsible block under the reply.", verdict: "keep", expectation: "The content stays the same, the warmth that hooks you goes.", diff: "4 files · +158 −31", tab: "Filter overlay"),

        // Onboarding and settings.
        text("2026-04-09 10:30", "Onboarding: how do you want to be protected?", node: "2309-26819", body: """
            How do you want to be protected?
            Sometimes the AI crosses a line, pretending to be human or building unhealthy attachment. Choose how Umbrella responds when this happens.

            Intervention: highlights manipulative phrases so you can see exactly what the AI is doing.
            Filtration: rewrites responses to remove manipulation, showing only what's actually useful.
            """, why: "The teen chooses the protection. Nothing is imposed.", tab: "Onboarding", tags: ["onboarding"]),
        text("2026-04-09 10:45", "Onboarding: how should we explain it?", node: "2309-26858", body: """
            How should we explain it?
            Choose the style of explanations you'll see when Umbrella flags something.

            Tool mode
            Friendly mode: warm and conversational. Plain language like a knowledgeable friend.
            """, tab: "Onboarding", tags: ["onboarding", "tone"]),
        text("2026-04-10 14:00", "Settings: on, quiet, off", node: "2296-26580", body: """
            Umbrella is...
            On: fully active. Phrases are highlighted, safety checks run, and the sidebar tracks patterns in real time.
            Quiet: on but low-key. No phrase highlights. Safety checks and sidebar tracking still run silently.
            Off: system paused. No highlights, no alerts, no sidebar.
            """, why: "Quiet is for chats where highlights would get in the way. The safety checks keep running.", tab: "Onboarding", tags: ["settings"]),

        // Testing.
        pic("2026-04-14 16:00", "d1k4kXYyMj4crNA8Ffz7sm3Wbs.jpg", "Testing with teens", seen: "A teen trying Umbrella on their own laptop and chatbot", why: "Their own prompts and their own accounts, not our script.", tab: "Testing", source: "Camera", tags: ["user testing", "teens", "own accounts"]),
        pic("2026-04-14 16:40", "GjXhQk2004QH7maV9W86SOlqneg.jpg", "Reading the annotations", seen: "Teen reading an annotated reply during the session", why: "They read the side notes before the reply itself.", tab: "Testing", source: "Camera", tags: ["user testing", "annotations"]),
        decision("2026-04-15 10:00", "What three teens showed us", body: "Two read the replies more critically afterwards. One took the rising dependency score as a cue to step back.", tab: "Testing"),
        pic("2026-04-16 11:30", "LS40tRiJgmq20yKq2oMeyWZdho.mp4", "Tone you can change", seen: "Recording: switching the explanations from tool to friendly", why: "Teens engaged more when the language matched how they think. Tool stays the default, friendly is a choice.", tab: "Testing", source: "Screen recording", tags: ["tone", "settings"]),
        decision("2026-04-16 12:00", "Tool by default, friendly on request", body: "\"Tool\" names the mechanism plainly: sycophancy, personification. \"Friendly\" says the same in their words. The teen picks.", tab: "Testing"),
        text("2026-04-17 15:10", "Expo print: attachment mechanisms", node: "2294-27713", body: """
            Attachment mechanisms
            Sycophancy: AI models are programmed to agree and validate
            Personification: AI claim feelings and personality
            Emotional mirroring: perform empathy without understanding
            Engagement loops: models drive endless curiosity and question rabbit holes
            Parasocial bonding: imply a real ongoing relationship
            """, tab: "Deck", tags: ["expo", "print", "mechanisms"]),

        // The four interventions, working.
        pic("2026-04-20 17:00", "j9dNX9TNRfy5cdqZNER1al9vAg.mp4", "Annotations with context", seen: "Recording: attachment phrases highlighted in a live chat, each with what the AI is doing", tab: "Final", source: "Screen recording", tags: ["annotations", "prototype"]),
        pic("2026-04-20 17:20", "YaBqbvhPKMyl80R4g0PsNMUW6Yg.mp4", "Sidebar overview", seen: "Recording: the dependency overview updating as the chat goes on", tab: "Final", source: "Screen recording", tags: ["sidebar", "prototype"]),
        pic("2026-04-21 15:00", "cKc2o2aj7goqzjH1W2ZLPjahA.mp4", "Popup interventions", seen: "Recording: the tiers of popups as a conversation escalates", why: "Light to heavy, in that order. The first popup is only a nudge.", tab: "Final", source: "Screen recording", tags: ["popups", "prototype"]),
        pic("2026-04-21 15:30", "AMAH95mx0xOlhoK4wowidheX3k.mp4", "Filtration", seen: "Recording: flagged patterns removed from a reply, the original one click away", tab: "Final", source: "Screen recording", tags: ["filtration", "prototype"]),
        pic("2026-04-22 11:00", "G4PF7LyFGTzp2VpHlzoY9fjzk.png", "Highlight: annotations", seen: "Case study highlight of the annotation layer", tab: "Final", tags: ["highlight"]),
        pic("2026-04-22 11:05", "uW08gWH227DlWVg9l0u0r8qN2E.png", "Highlight: sidebar", seen: "Case study highlight of the sidebar", tab: "Final", tags: ["highlight"]),
        pic("2026-04-22 11:10", "6QHbfOYHx0gNbfVkxQGpd2akv0.png", "Highlight: popups", seen: "Case study highlight of the popups", tab: "Final", tags: ["highlight"]),
        pic("2026-04-23 10:00", "NAJMhtuGmgZLnJa4k9dQ2C0AgE.jpg", "Umbrella", seen: "Umbrella running over a live chat", tab: "Final", tags: ["hero"]),

        // Out into the world.
        pic("2026-04-28 18:00", "RGQEyWiCKPasBH6LnySuVXdsok.png", "Presented to Common Sense Media", seen: "Presenting Umbrella to Common Sense Media", why: "Adults in the room asked to use it themselves. The mechanisms work on everyone.", kind: .decision, tab: "Final", source: "Camera", tags: ["Common Sense Media", "presentation", "feedback"]),
        pic("2026-04-28 18:30", "Sj8z1fEBogtpyFDL1i4nKwzcGmk.png", "Beyond teens", seen: "Any engagement-optimised system uses these mechanisms", tab: "Final", tags: ["impact"]),
        pic("2026-04-30 12:00", "MExQP8yNxjmBmUZNwrD38AhYyYc.mp4", "Introducing Umbrella", seen: "Film introducing Umbrella", tab: "Final", source: "Premiere", tags: ["film"]),
        pic("2026-05-06 10:00", "VlCIQTIWCELWxiCGoQFIgqX5g0w.jpeg", "Reflection", seen: "The team after the final presentation", why: "Friendly mode works because it's anthropomorphic, and Umbrella runs on an LLM too. We use attachment to build independence from the model, not more time in it. Defensible, not perfect.", kind: .decision, tab: "Final", source: "Camera", tags: ["reflection", "team", "anthropomorphism"]),
    ]

    /// Better names and tabs for the shipped captures (by id), so the
    /// archive reads as a story: raw Figma frame names like "popup3" go.
    private static let shippedNames: [String: (title: String, tab: String)] = [
        "70CF131D": ("How might we", "Research"),
        "848FE805": ("The problem in three numbers", "Research"),
        "EEFE1217": ("Gemini says yes to friendship", "Research"),
        "43214817": ("Gemini's friendship reply", "Research"),
        "2E23F221": ("Type on a pink grid", "Visual references"),
        "22CA9AA6": ("Brain fog lettering", "Visual references"),
        "AB963643": ("Halftone letter", "Visual references"),
        "C5F5671E": ("Info bar and color-coded text", "Intervention concepts"),
        "E29B09AA": ("Summary for a counselor", "Intervention concepts"),
        "FB4322E1": ("Full filtration", "Intervention concepts"),
        "EC1741AE": ("Rewrite with See original", "Intervention concepts"),
        "4551D0A1": ("Filter v1, gradient", "Filter overlay"),
        "44ADC9F5": ("Filter v2, no border", "Filter overlay"),
        "D010A79C": ("Tier 1 reminder", "Filter overlay"),
        "65BBB7A3": ("Comments like a Google Doc", "Annotation cards"),
        "A70EE2AB": ("Card variants", "Annotation cards"),
        "F033A59B": ("An overview score", "Sidebar"),
        "735A18BE": ("A parent dashboard", "Intervention concepts"),
        "C5B00361": ("Take a break", "Escalating popups"),
        "F138F527": ("Reply blocked", "Escalating popups"),
        "8BEE5683": ("Deck title", "Deck"),
        "D9AEDB3D": ("Hero slide", "Deck"),
        "65908CC9": ("Agenda", "Deck"),
    ]

    // MARK: The other projects

    static let others: [Project] = [
        Project(name: "Sona", cover: cdn + "bWRuK0kFV287Gxq0zKTUtQvBldQ.png", items: [
            pic("2025-03-03 09:30", "5XRGH1chRZAIMkEiHQ6Ose8oNE.png", "Highlights", seen: "Sona at a glance: a neck wearable for stress and focus", tab: "Research", tags: ["overview"]),
            pic("2025-03-04 10:20", "Sl5uHgwpuLR6cWuo0GJaS02ODgA.png", "Stress as the problem", seen: "Slide on chronic stress from constant digital input", why: "Framed it as a health problem, not a productivity one.", tab: "Research", tags: ["research", "stress"]),
            pic("2025-03-05 15:40", "rzQAfG3tyqqvO3mOxs1Svy4ELs4.png", "Burnout and shallow focus", seen: "Problem space slide on burnout and fragmented attention", tab: "Research", tags: ["research"]),
            pic("2025-03-11 11:05", "qBUZrak3S4tLBK162FgAovBeEY.png", "Competitive field", seen: "Map of stress tools by tracking, training and senses", why: "Every tool covers one fragment. None works without your attention.", tab: "Research", tags: ["competition", "map"]),
            pic("2025-03-18 14:30", "4u3DCtf1cuicEupy0NOMn0AYKlo.png", "Shift your state in real time", seen: "Commute, work and home as three moments of use", tab: "Concept", tags: ["benefit", "scenarios"]),
            pic("2025-03-25 09:50", "BE6RBBwAECvdtVvqEPOpUqkBvwk.png", "Measure, interpret, pulse", seen: "Loop from biodata to state to rhythmic haptic pulses", why: "A closed loop with no screen. The body is the interface.", kind: .decision, tab: "Concept", tags: ["system", "loop"]),
            pic("2025-04-01 16:15", "Mg5RHNWm9BcInFGuJLxDkd16aE.png", "A model picks the rhythm", seen: "An LLM turning the interpreted state into rhythm parameters", why: "Tempo and intensity from the state, not presets. Built the pipeline with Codex.", tab: "Concept", source: "Cursor", tags: ["llm", "rhythm"]),
            pic("2025-04-07 10:00", "EYOesfWiEGVq90T7jgCzqavY2Q.png", "Sketches around the neck", seen: "Paper sketches of neck-worn forms", tab: "Form", source: "Camera", tags: ["sketch", "form"]),
            pic("2025-04-10 13:25", "pHbYmXsEJaoLRxV5ekjgkUeZuFA.png", "Lidar scans into CAD", seen: "Scanned necks next to the first CAD surfaces", why: "Real necks, not a mannequin.", tab: "Form", source: "Rhino", tags: ["lidar", "cad"]),
            pic("2025-04-16 17:40", "5TvdSZxPCOQiS5N8UYw7whWC60.png", "Prints in PETG and TPU", seen: "A row of 3D printed neck pieces in different fits", why: "Early versions were bulky. Each print fixed fit or motor placement.", tab: "Form", source: "Camera", tags: ["prototype", "print"]),
            pic("2025-04-18 11:00", "5GKzFQTtit3WPLG4vteJuR0LTNI.png", "Form study", seen: "Form study of the band around the neck", tab: "Form", source: "Rhino", tags: ["form"]),
            pic("2025-04-21 15:20", "z4hFof0V8QCVD48FvcJ3jsnTX0I.png", "Motor layout", seen: "Placement of the haptic motors along the band", tab: "Form", source: "Rhino", tags: ["motors", "form"]),
            pic("2025-04-24 12:10", "DFhC4K790CqfL3nCGdOP1XgLOw0.png", "Final parts in nylon SLS", seen: "High-detail nylon SLS parts of the final form", why: "SLS for the surface quality jewelry needs.", kind: .decision, tab: "Form", source: "Camera", tags: ["material", "final"]),
            pic("2025-05-02 10:30", "PscbY3uCqZzIW9WuzMZobeNa60.png", "Ten interviews", seen: "Interview insights on stress, touch and wearables", tab: "Testing", tags: ["interviews"]),
            pic("2025-05-05 14:00", "BIOQFYbY9MvS7rFsHeBs60AoTWY.png", "Who we talked to", seen: "Interview participants and what they said about stress", tab: "Testing", tags: ["interviews"]),
            pic("2025-05-08 15:00", "j8w0GsxIfL3dkuwIyGMXYqzygo.jpg", "Three motors and a controller", seen: "Working prototype wired with motors, controller and battery", tab: "Testing", source: "Camera", tags: ["prototype", "electronics"]),
            pic("2025-05-12 16:30", "gU2vubZwEa1WVhbuCyzLfMPNg0.jpg", "Test session", seen: "A participant wearing the prototype during a test", tab: "Testing", source: "Camera", tags: ["testing"]),
            pic("2025-05-15 11:45", "BqjasLolkMhp6SGGfmuXEcxqc.png", "33% more positive states", seen: "STAI results from 20 participants", why: "Enough signal to keep rhythm as the core.", kind: .decision, tab: "Testing", tags: ["results", "stai"]),
            pic("2025-05-20 10:00", "o4j7B07LPSa3VsamrOJLfz5tFpU.jpg", "Sona, photographed", seen: "The finished Sona on a plain background", tab: "Final", source: "Camera", tags: ["photo", "final"]),
            pic("2025-05-22 14:20", "aPqCLr66fk6C8Z1FUqpSWGJpkrA.png", "Jewelry, not a device", seen: "Sona worn like a necklace", why: "A jewelry-like form takes the stigma out of a mental health tool.", kind: .decision, tab: "Final", source: "Camera", tags: ["final", "form"]),
            pic("2025-05-24 11:10", "6hicgSchSSAM3YlRCXrVVKI3eoY.png", "Calm technology", seen: "Design principles from Calm Technology and Emotional Design", tab: "Final", tags: ["principles"]),
            pic("2025-05-28 16:05", "YpAtS4HE8hiVfId6BeLFWLWqw.png", "Touch for intensity, app for setup", seen: "Haptic surface on the device next to the onboarding app", tab: "Final", tags: ["interaction", "app"]),
            pic("2025-05-30 18:30", "7GOYsCligk9CiCOrLSXkAIeZfY.png", "Reflection", seen: "Sona for commuters, students, professionals and caregivers", tab: "Final", tags: ["reflection"]),
        ]),
        Project(name: "RAUFASER", cover: cdn + "uQ83t15NmFB9KQJR7ZiIOHb2W0.png", items: [
            pic("2024-10-21 10:00", "08hyJU93rasVSmGez341hHxVo.jpg", "Fashion as a closed system", seen: "Portrait for the problem: exclusive, opaque, disconnected", why: "Start from what's wrong with fashion, not from a look.", tab: "Concept", source: "Camera", tags: ["problem"]),
            pic("2024-11-05 11:00", "yD0XdKFK4GHH8QJC6ZmQcctA0E.png", "Black, white and grey", seen: "Brand identity in brutalist minimalism", why: "Raw minimalism that won't date with the seasons.", kind: .decision, tab: "Identity", tags: ["identity", "brand"]),
            pic("2024-11-20 15:30", "cyAClZjh6Llg4HAW7JruEyX9rY.png", "A monochrome site in motion", seen: "Website with the collection and motion elements", tab: "Identity", source: "Framer", tags: ["website"]),
            pic("2024-12-02 12:00", "LdA2PELSnQ8ike3wvG893hkHhE.png", "Overview", seen: "RAUFASER at a glance: fashion, art and technology", tab: "Identity", tags: ["overview"]),
            pic("2025-01-14 13:10", "ly7Or8xWVRFdLuXJUuFunPDXEUo.png", "Handmade in Berlin", seen: "Garments with sculptural silhouettes", why: "Limited runs, handmade. No seasons, a permanent serie.", tab: "Collection", tags: ["garments"]),
            pic("2025-02-10 10:40", "SRWKARbqenJa1QXrixtYhSpDvVc.webp", "Fashion as collective experiment", seen: "Concept board for co-creation, events and workshops", tab: "Concept", tags: ["concept"]),
            pic("2025-03-03 17:20", "EMNJAgadhF7qqor7wLgi7nXKjLI.webp", "Raw, responsible, transparent", seen: "Ethos page with a look on a plain wall", tab: "Concept", tags: ["ethos"]),
            pic("2025-04-22 12:00", "0ZIExxSRSa0WjYvvPsklNR6SA.jpg", "Look 01", seen: "Full-length portrait of a raw-edged look", tab: "Collection", source: "Camera", tags: ["look", "photo"]),
            pic("2025-04-22 12:30", "4GwZSB2G9NyRhwbP4vNoMXvqg.jpg", "Look 02", seen: "Sculptural silhouette in grey", tab: "Collection", source: "Camera", tags: ["look", "photo"]),
            pic("2025-04-22 13:00", "UbHq0OhV15aMDjjfOtcDcTCuSk.jpg", "Look 03", seen: "A look photographed against concrete", tab: "Collection", source: "Camera", tags: ["look", "photo"]),
            pic("2025-07-27 21:15", "LTvHwxr57azYMRORIhhJzJuSk.jpg", "Launch at Salon am Moritzplatz", seen: "Crowd at the launch evening", why: "Fashion, performance, art and music in one night. 600 guests.", tab: "Events", source: "Camera", tags: ["launch", "event"]),
            pic("2025-07-27 22:40", "hmDf7NmfVaSfnlBlRegI1BB7Us.jpg", "Launch night", seen: "Live performance in the salon", tab: "Events", source: "Camera", tags: ["event"]),
            pic("2025-07-28 12:00", "mjJ4FsfPgoWcbX3jnxG9cEyHFVA.jpg", "The morning after", seen: "Wide shot of the launch space", tab: "Events", source: "Camera", tags: ["event"]),
            pic("2025-09-10 16:00", "2S4yQwrLfacRpXQtz3a8gEgRA.png", "Skulpturaler Moment", seen: "Four looks frozen in epoxy on white monobloc chairs", why: "Freeze the garment so it reads as sculpture at an art fair.", kind: .decision, tab: "Events", tags: ["installation", "positions"]),
            pic("2025-09-12 18:30", "bzz16wRiOpgPOSGyJnWTWE7QF2w.jpg", "POSITIONS Berlin", seen: "The installation at Berlin Art Week", tab: "Events", source: "Camera", tags: ["positions", "event"]),
            pic("2025-09-13 11:00", "qSzjOarFu4d4s0KmkRU5kB84.jpg", "One of 20 brands", seen: "RAUFASER among the 20 Berlin brands at Fashion Positions", tab: "Events", source: "Camera", tags: ["positions"]),
            pic("2025-10-17 20:00", "vskoyxn67QrVfhJH4BudgIJP8jM.jpeg", "NOTAGALLERY", seen: "The collection on show at NOTAGALLERY Berlin", tab: "Events", source: "Camera", tags: ["exhibition"]),
            pic("2025-10-17 21:30", "utT4IV9yZe1O0b5eeFRQRH9XdWY.jpg", "300 guests", seen: "Guests at the NOTAGALLERY opening", tab: "Events", source: "Camera", tags: ["exhibition"]),
            pic("2025-10-25 10:00", "qZJ2rKHSd7IOfPxxg4sg7tTf5so.png", "Reflection", seen: "Fashion as an experimental, human-centered medium", why: "A research space next to product work: material, technology and presentation.", tab: "Concept", tags: ["reflection"]),
        ]),
        Project(name: "PAL", cover: cdn + "TYgXc9Ksh1eDlVERy021iM8j78.png", items: [
            pic("2023-04-12 10:15", "SNqkoey2xZLddc73pkU7b0i9dA.png", "Electricity up 600%", seen: "Chart of German electricity prices in 2022", tab: "Research", tags: ["research", "energy"]),
            pic("2023-04-13 14:00", "S4qE25TeP12paHTvUe0ATE7Fws.png", "An aging population", seen: "Only 6% of people over 75 use smart home systems", why: "The people who'd save most are the least able to use it.", tab: "Research", tags: ["research", "aging"]),
            pic("2023-04-20 11:30", "saAyXTsmMUUH6g2m78f8umDlG2g.png", "Alexa, Google Home, HomeKit", seen: "Comparison of smart home platforms", why: "All assume digital literacy and talk about technology, not people.", tab: "Research", tags: ["competition"]),
            pic("2023-04-26 16:10", "9wCNKQkci1rzpeimAdvcEdbExc.png", "Living on their own", seen: "Target user: older residents staying independent", tab: "Research", tags: ["persona"]),
            pic("2023-05-03 10:45", "sZtwoume53gYtyuW5tTOBPmL7XY.png", "User journey", seen: "A day with smart home touchpoints and pain points", tab: "Concept", tags: ["journey"]),
            pic("2023-05-10 13:20", "uDxF2EpYL5KjSn2cDtfLV7YDo.png", "How might we", seen: "How might we questions reframing the smart home", tab: "Concept", tags: ["hmw"]),
            pic("2023-05-16 15:50", "fePMZH3NN2iwfemWohusGZ93dQ.png", "System map", seen: "Sensors, devices and interfaces in daily routines", tab: "Concept", tags: ["system", "map"]),
            pic("2023-05-24 11:00", "PHHz7Ozhe2LBctInm3GzC8D0gJM.png", "A leaf instead of charts", seen: "The leaf companion showing saving and waste", why: "A character's mood reads faster than a graph.", kind: .decision, tab: "Design", tags: ["character", "metaphor"]),
            pic("2023-05-31 14:35", "zNIBMyvNcdKPILne1GQIWE5Jg.png", "Large dashboards", seen: "Energy data in large, readable widgets", tab: "Design", tags: ["dashboard"]),
            pic("2023-06-02 10:00", "QKJQ20fp3o06y4J6ORX7SCRaww.png", "Teach, don't only show", seen: "Screens explaining cleaner energy and everyday impact", tab: "Design", tags: ["education"]),
            pic("2023-06-07 10:20", "uyXPnGo2JElqyFdksckYTaNI0.png", "Wireframes", seen: "Iterations of the app's screens", tab: "Design", tags: ["wireframes"]),
            pic("2023-06-14 16:00", "nHsfZSFIFNbk8sY6SXqbnuYvSG4.png", "Design system", seen: "Widgets, expressions and components", tab: "Design", tags: ["design system"]),
            pic("2023-06-21 12:40", "ysL6v7v3oOBKVBGxex1PuZUdQ.png", "Physical mock-ups", seen: "Foam models tested for grip and reach", why: "Test the object in hand before the screen.", tab: "Testing", source: "Camera", tags: ["mockup", "testing"]),
            pic("2023-06-28 15:15", "tuwdnvSjO0ogqbEErINQ5lpyQ.png", "In VR", seen: "Interface and home functions simulated in VR", tab: "Testing", tags: ["vr", "prototype"]),
            pic("2023-07-04 10:00", "ElyFAezPvCjq2o8vTKZAxTZZMIs.png", "Fits any home", seen: "PAL as a minimal companion in different households", tab: "Final", tags: ["final"]),
            pic("2023-07-05 11:30", "xVwqHVwD3LhsA0du0BjeRlfXVNY.png", "The app mirrors the object", seen: "Mobile interface with tracking and tips", tab: "Final", tags: ["app"]),
            pic("2023-07-06 14:00", "A8iYqsUhMFH0OzpPFdckd5aMQ.png", "One ecosystem", seen: "PAL connecting sensors, devices and the app", tab: "Final", tags: ["ecosystem"]),
            pic("2023-07-12 17:00", "eQEtsHWKedFylztxIg4DrUyaqwQ.png", "Reflection", seen: "PAL in a living room", why: "Feedback works through form and tone, not only accurate data.", tab: "Final", tags: ["final"]),
        ]),
        Project(name: "Aura", cover: nil, items: [
            Item(when: "2024-04-08 10:00", kind: .note, title: "Starting point", tab: "Research", body: "Dementia care runs on small interactions between patients and caregivers. Where could AI help those moments without replacing them?"),
            Item(when: "2024-05-13 16:30", kind: .note, title: "Direction", tab: "Concept", body: "AI-driven interactions that support the caregiver and keep the patient at the center."),
            pic("2024-06-20 15:00", "zgbmbpRBZNKeVtEkhWArBEyhEQ.mp4", "Aura in use", seen: "Film of Aura between a patient and a caregiver", tab: "Final", source: "Premiere", tags: ["film"]),
        ]),
    ]

    // MARK: Seeding

    private static var running = false

    /// Adds what's missing. Only for the demo archive.
    static func seedIfNeeded(into store: EntryStore) {
        // A download ships its projects complete (Umbrella and Margin only).
        guard !DemoData.isDownloadedBuild, DemoData.isOn, store.baseURL.standardizedFileURL == DemoData.baseURL.standardizedFileURL, !running else { return }
        removeSamples(from: store)
        tidyUmbrella(in: store)
        nameShipped(in: store)
        guard !UserDefaults.standard.bool(forKey: version) else { return }
        running = true
        Task {
            var complete = await setCover(cdn + "NAJMhtuGmgZLnJa4k9dQ2C0AgE.jpg", for: DemoData.project, in: store, key: "portfolioDemo.umbrellaCover.v2")
            complete = await add(Project(name: DemoData.project, cover: nil, items: umbrella), to: store) && complete
            for project in others {
                complete = await add(project, to: store) && complete
            }
            if complete { UserDefaults.standard.set(true, forKey: version) }
            running = false
            MarginLog.info("Demo: built out\(complete ? "" : ", some pictures still to come")")
        }
    }

    /// Adds the project's missing captures; true when nothing failed.
    private static func add(_ project: Project, to store: EntryStore) async -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-demo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var complete = true

        for item in project.items {
            let id = stableID(project.name + "|" + item.key)
            // Already there: by id, or by name from the first version of this demo.
            let existing = store.entries(in: project.name)
            if store.entry(id: id) != nil || existing.contains(where: { $0.ai?.title == item.title || (!$0.title.isEmpty && $0.title == item.title) }) {
                continue
            }
            if let address = item.url {
                guard let file = await download(address, into: folder) else { complete = false; continue }
                let added = await FileImport.importFiles([file], into: store, project: project.name)
                guard let entry = added.first else { complete = false; continue }
                store.modify(entry.id) { e in
                    e.id = id
                    if e.kind != .recording { e.kind = item.kind }
                    fill(&e, with: item, project: project.name)
                }
            } else {
                var entry = Entry(kind: item.kind, project: project.name)
                entry.id = id
                fill(&entry, with: item, project: project.name)
                store.add(entry)
            }
        }
        if let cover = project.cover {
            complete = await setCover(cover, for: project.name, in: store, key: nil) && complete
        }
        return complete
    }

    private static func fill(_ e: inout Entry, with item: Item, project: String) {
        let when = date(item.when)
        e.createdAt = when
        e.label = nil
        e.sourceApp = item.source
        e.rationale = item.why
        e.tab = item.tab
        e.tags = []
        e.link = item.node.map { figmaFile + $0 } ?? ""
        switch item.kind {
        case .decision:
            e.title = item.title
            e.body = item.body
        case .note:
            e.title = item.title
            e.body = item.body
        case .text:
            e.body = item.body
            e.windowTitle = "Umbrella Design"
        case .iteration:
            e.prompt = item.prompt
            e.summary = item.summary
            e.verdict = item.verdict
            e.expectation = item.expectation
            e.diffStat = item.diffStat
            e.agent = "Claude Code"
        default:
            e.windowTitle = project
        }
        if item.kind != .decision, item.kind != .note, item.kind != .iteration {
            e.ai = CaptureNote(title: item.title, seen: item.seen.isEmpty ? item.title : item.seen, tags: item.tags, topic: item.tab, model: "demo", createdAt: when)
        }
    }

    /// A project's cover, once (the key remembers it; without a key, only
    /// while the project has none).
    private static func setCover(_ address: String, for project: String, in store: EntryStore, key: String?) async -> Bool {
        if let key, UserDefaults.standard.bool(forKey: key) { return true }
        if key == nil, ProjectCovers.has(project, in: store) { return true }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-cover-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let file = await download(address, into: folder), let image = NSImage(contentsOf: file) else { return false }
        ProjectCovers.set(image, for: project, in: store)
        if let key { UserDefaults.standard.set(true, forKey: key) }
        return true
    }

    /// Readable names and tabs for the shipped Umbrella captures, once.
    private static func nameShipped(in store: EntryStore) {
        let key = "portfolioDemo.shippedNames.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for entry in store.entries(in: DemoData.project) {
            let prefix = String(entry.id.uuidString.prefix(8))
            guard let name = shippedNames[prefix] else { continue }
            store.modify(entry.id) { e in
                e.label = nil
                e.tab = name.tab
                if e.ai != nil {
                    e.ai?.title = name.title
                } else {
                    e.ai = CaptureNote(title: name.title, seen: name.title, tags: [], topic: name.tab, model: "demo", createdAt: e.createdAt)
                }
            }
        }
    }

    /// Captures made in demo mode that aren't Umbrella's (Margin's own
    /// work, captured while the demo was on) move to a project of their
    /// own, so Umbrella tells one story. Nothing is deleted. Once.
    private static func tidyUmbrella(in store: EntryStore) {
        let key = "portfolioDemo.tidyUmbrella.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        var shipped = Set<UUID>()
        if let url = DemoData.bundledURL?.appendingPathComponent("entries.json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in list { if let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) { shipped.insert(id) } }
        }
        guard !shipped.isEmpty else { return }
        let ours = Set(umbrella.map { stableID(DemoData.project + "|" + $0.key) })
        let strays = store.entries(in: DemoData.project).filter { !shipped.contains($0.id) && !ours.contains($0.id) && $0.ai?.model != "demo" }
        for entry in strays { store.modify(entry.id) { $0.project = "Margin" } }
        if !strays.isEmpty { MarginLog.info("Demo: moved \(strays.count) captures from Umbrella to Margin") }
    }

    /// The made-up Field Notes and Tidal from an earlier build.
    private static func removeSamples(from store: EntryStore) {
        let samples = store.entries.filter { ["Field Notes", "Tidal"].contains($0.project) && $0.ai?.model == "sample" }
        guard !samples.isEmpty else { return }
        for entry in samples { store.delete(entry) }
        ProjectCovers.clear("Field Notes", in: store)
        ProjectCovers.clear("Tidal", in: store)
    }

    // MARK: Helpers

    /// The same id for the same capture, every time.
    private static func stableID(_ key: String) -> UUID {
        let bytes = Array(Insecure.MD5.hash(data: Data(key.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Downloads one picture (at most 1600 px wide) or film into `folder`.
    private static func download(_ address: String, into folder: URL) async -> URL? {
        let isImage = address.hasPrefix(cdn)
        guard let url = URL(string: isImage ? address + "?scale-down-to=1600" : address) else { return nil }
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let name = URL(string: address)?.lastPathComponent ?? UUID().uuidString
            let target = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            return target
        } catch {
            MarginLog.info("Demo download failed for \(address): \(error)")
            return nil
        }
    }

    private static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text) ?? Date()
    }
}
