import Foundation
import MarginKit

// margin-mcp: lets Claude (the desktop app, in any chat or Claude project)
// document a project's process into Margin.
//
// An MCP server over stdio: one JSON-RPC message per line in, one per line
// out. It passes Claude's calls on to Margin's local server (127.0.0.1),
// so it only works while Margin is open, on the same Mac.

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Reaching Margin

/// Margin's local server: the port it wrote down, else the first that answers.
func marginBase() -> URL? {
    let portFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".margin/port")
    var ports: [Int] = []
    if let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        ports.append(port)
    }
    ports += (47821...47830).filter { !ports.contains($0) }
    for port in ports {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        if let reply = call(base.appendingPathComponent("margin/hello"), timeout: 1.5), reply["app"] as? String == "Margin" {
            return base
        }
    }
    return nil
}

/// A request to Margin; the JSON it answers with.
func call(_ url: URL, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 120) -> [String: Any]? {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    if let body {
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let done = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    URLSession.shared.dataTask(with: request) { data, _, _ in
        if let data { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + timeout + 1)
    return result
}

// MARK: What Claude sees

let instructions = """
Margin is the designer's process archive: a timeline of captures (pictures, Figma frames, websites, text, decisions) per project. \
Use these tools when the designer asks to document a project, a chat or their process in Margin. \
Check what the Margin project already has first, then add captures in batches, each placed at the date it happened.
"""

let skill = MarginSkill.body

let tools: [[String: Any]] = [
    [
        "name": "margin_projects",
        "description": "Lists the projects in the designer's Margin archive, with how many captures each has and their first and last dates.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
    [
        "name": "margin_project",
        "description": "What one Margin project already has: its captures with titles, kinds, dates and links (newest first). Check this before adding, so nothing is added twice.",
        "inputSchema": [
            "type": "object",
            "properties": ["name": ["type": "string", "description": "The Margin project's name."]],
            "required": ["name"],
        ],
    ],
    [
        "name": "margin_about",
        "description": "Sets a Margin project's About text: what the project is, who it's for, what the designer is trying to find out. Ask, the hand off and Claude read it. Replaces the text; margin_project shows the current one, and the answer returns what it was before.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "The Margin project's name."],
                "about": ["type": "string", "description": "The full About text, a few short paragraphs at most."],
            ],
            "required": ["project", "about"],
        ],
    ],
    [
        "name": "margin_add",
        "description": "Adds captures to a Margin project's timeline, each at the date it happened. Up to 20 per call, oldest first. A project that doesn't exist yet is made. Margin fetches pictures itself: Figma frames from figma_url, pictures from image_url, websites from link. Files on the designer's Mac come in from `file` (a full path): HTML pages and site folders become live prototypes you can click through, images pictures, videos recordings, text notes, anything else the file with its preview. A page that only exists in this chat (an HTML artifact) can be passed as `html`. Captures already in the project are skipped.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "project": ["type": "string", "description": "The Margin project's name."],
                "captures": [
                    "type": "array",
                    "maxItems": 20,
                    "items": [
                        "type": "object",
                        "properties": [
                            "kind": ["type": "string", "enum": ["note", "decision", "text", "link", "figma", "inspiration", "image", "prototype", "recording", "file"]],
                            "title": ["type": "string", "description": "Short and specific."],
                            "body": ["type": "string", "description": "What it was and what it changed, a few sentences."],
                            "when": ["type": "string", "description": "When it happened: YYYY-MM-DD or an ISO 8601 time."],
                            "link": ["type": "string", "description": "A website or document address."],
                            "figma_url": ["type": "string", "description": "A Figma link with node-id, for a frame."],
                            "image_url": ["type": "string", "description": "A public address of a picture."],
                            "file": ["type": "string", "description": "A full path to a file or folder on the designer's Mac (e.g. /Users/name/Desktop/build/index.html). HTML pages and folders with an index.html become live prototypes; kind can say what else it should be."],
                            "html": ["type": "string", "description": "The complete HTML of a page made in this chat (an artifact or a prototype), to keep as a live prototype."],
                            "why": ["type": "string", "description": "The designer's own words for why, quoted. Leave out if they didn't say."],
                            "alternatives": ["type": "string", "description": "Decisions: what else was considered."],
                            "source": ["type": "string", "description": "Where it came from, e.g. Claude chat, Figma."],
                            "tags": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["kind", "title", "when"],
                    ],
                ],
            ],
            "required": ["project", "captures"],
        ],
    ],
]

let prompts: [[String: Any]] = [
    [
        "name": "document_project",
        "description": "Document this work's process so far in Margin",
        "arguments": [["name": "project", "description": "The Margin project to add to", "required": false]],
    ],
]

// MARK: Answering

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

func reply(_ id: Any, _ result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func fail(_ id: Any, _ code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func text(_ value: Any, isError: Bool = false) -> [String: Any] {
    let body: String
    if let string = value as? String {
        body = string
    } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        body = String(decoding: data, as: UTF8.self)
    } else {
        body = "\(value)"
    }
    return ["content": [["type": "text", "text": body]], "isError": isError]
}

func runTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
    guard let base = marginBase() else {
        return text("Margin isn't open on this Mac. Open Margin, then try again.", isError: true)
    }
    switch name {
    case "margin_projects":
        return call(base.appendingPathComponent("margin/projects")).map { text($0) } ?? text("Margin didn't answer.", isError: true)
    case "margin_project":
        var components = URLComponents(url: base.appendingPathComponent("margin/project"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: arguments["name"] as? String ?? "")]
        return call(components.url!).map { text($0) } ?? text("Margin didn't answer.", isError: true)
    case "margin_about":
        guard let answer = call(base.appendingPathComponent("margin/about"), method: "POST", body: arguments, timeout: 30) else {
            return text("Margin didn't answer.", isError: true)
        }
        return text(answer, isError: answer["error"] != nil)
    case "margin_add":
        guard let answer = call(base.appendingPathComponent("margin/captures"), method: "POST", body: arguments, timeout: 240) else {
            return text("Margin didn't answer in time. Some captures may have been added: check the project with margin_project before trying again.", isError: true)
        }
        return text(answer, isError: answer["error"] != nil)
    default:
        return text("There's no tool called \(name).", isError: true)
    }
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    // Notifications have no id and get no answer.
    guard let id = message["id"] else { continue }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        reply(id, [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
            "serverInfo": ["name": "margin", "version": "1.0"],
            "instructions": instructions,
        ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        reply(id, runTool(name, params["arguments"] as? [String: Any] ?? [:]))
    case "prompts/list":
        reply(id, ["prompts": prompts])
    case "prompts/get":
        let project = ((params["arguments"] as? [String: Any])?["project"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let ask = project.isEmpty ? "Document this work's process so far in Margin." : "Document this work's process so far in Margin, in the Margin project \"\(project)\"."
        reply(id, [
            "description": "Document this work's process so far in Margin",
            "messages": [["role": "user", "content": ["type": "text", "text": ask + "\n\n" + skill]]],
        ])
    case "resources/list":
        reply(id, ["resources": [Any]()])
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}
