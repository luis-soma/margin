import Foundation
import MarginKit
import SwiftUI

/// A group on the map as it stands: a theme (with its name at the big
/// picture) or a pattern inside one (with its name at the closer steps).
struct MapGroup: Codable, Equatable {
    var key: String
    var title: String
    /// You named it: Margin never renames it.
    var mine: Bool
    /// For a pattern: its theme's key.
    var parent: String?
    /// Where its name sits, on the map.
    var label: MapPoint
    /// Captures Margin thinks might belong here, offered, never moved.
    var suggested: [String]

    init(key: String, title: String, mine: Bool = false, parent: String? = nil, label: MapPoint, suggested: [String] = []) {
        self.key = key
        self.title = title
        self.mine = mine
        self.parent = parent
        self.label = label
        self.suggested = suggested
    }
}

/// A project's map as it stands. Margin sorts it once, as a starting point;
/// from then on it's yours. Your changes stay where you make them, nothing
/// else moves, and new captures settle into the free spot nearest the group
/// they fit, without moving anything already there.
struct Arrangement: Codable, Equatable {
    var themes: [MapGroup]
    var patterns: [MapGroup]
    /// Which theme and pattern each capture is in.
    var themeOf: [String: String]
    var patternOf: [String: String]
    /// Each capture's centre at the big picture and at the closer steps.
    var far: [String: MapPoint]
    var near: [String: MapPoint]
    /// The zoom the map was drawn for, and the step between scales.
    var fit: Double
    var ratio: Double
    /// You've changed something: from now on Margin only suggests.
    var touched: Bool
    /// Each capture has room under it for its note (maps from before didn't).
    var notesRoom: Bool?
}

extension ProjectMaps {
    static let mapGap = 10.0
    /// Room for a note under each capture at the close-up, on screen.
    static let noteHeight = 40.0

    // MARK: Geometry

    func artifactSize(_ id: String) -> MapSize {
        guard let uuid = UUID(uuidString: id), let entry = store.entry(id: uuid) else {
            return MapSize(width: Double(Self.side), height: Double(Self.side) * 0.7)
        }
        let s = mapSize(for: entry)
        return MapSize(width: Double(s.width), height: Double(s.height))
    }

    func noteRoom(_ a: Arrangement) -> Double { Self.noteHeight / (a.fit * pow(a.ratio, 3)) }

    func members(of key: String, tier: Int, in a: Arrangement) -> [String] {
        (tier == 1 ? a.themeOf : a.patternOf).filter { $0.value == key }.map(\.key).sorted()
    }

    /// The room a name takes on the map, at the zoom it's read at.
    func labelBox(_ group: MapGroup, tier: Int, in a: Arrangement) -> MapBox {
        let screen = PatternLabel.size(title: group.title, count: members(of: group.key, tier: tier, in: a).count)
        let z = tier == 1 ? a.fit : a.fit * a.ratio
        return MapBox(x: group.label.x, y: group.label.y, width: screen.width / z, height: screen.height / z)
    }

    /// Everything in one of the two layouts: its captures and its names.
    func obstacles(_ a: Arrangement, far: Bool, except: Set<String> = []) -> [MapBox] {
        let note = noteRoom(a)
        var out: [MapBox] = []
        for (id, p) in far ? a.far : a.near where !except.contains(id) {
            let s = artifactSize(id)
            out.append(MapBox(x: p.x, y: p.y + note / 2, width: s.width, height: s.height + note))
        }
        if far {
            for g in a.themes { out.append(labelBox(g, tier: 1, in: a)) }
        } else {
            for g in a.patterns { out.append(labelBox(g, tier: 0, in: a)) }
        }
        return out
    }

    /// The free spot nearest `target` for a capture, in one layout.
    func settle(_ id: String, near target: MapPoint, far: Bool, in a: Arrangement) -> MapPoint {
        let note = noteRoom(a)
        let s = artifactSize(id)
        let spot = TreeLayout.freeSpot(near: MapPoint(x: target.x, y: target.y + note / 2),
                                       size: MapSize(width: s.width, height: s.height + note),
                                       avoiding: obstacles(a, far: far, except: [id]), gap: Self.mapGap, step: 12)
        return MapPoint(x: spot.x, y: spot.y - note / 2)
    }

    func middle(of members: [String], far: Bool, in a: Arrangement) -> MapPoint? {
        let points = members.compactMap { (far ? a.far : a.near)[$0] }
        guard !points.isEmpty else { return nil }
        return MapPoint(x: points.reduce(0) { $0 + $1.x } / Double(points.count),
                        y: points.reduce(0) { $0 + $1.y } / Double(points.count))
    }

    /// Captures that sit under a name (after it was renamed or added) step
    /// aside to the nearest free spot. Nothing else moves.
    private func clear(_ a: inout Arrangement, far: Bool, keys: Set<String>) {
        let groups = far ? a.themes : a.patterns
        let note = noteRoom(a)
        for group in groups where keys.contains(group.key) {
            let label = labelBox(group, tier: far ? 1 : 0, in: a)
            for (id, p) in far ? a.far : a.near {
                let s = artifactSize(id)
                let y = p.y + note / 2
                guard abs(p.x - label.x) < (s.width + label.width) / 2 + Self.mapGap / 2,
                      abs(y - label.y) < (s.height + note + label.height) / 2 + Self.mapGap / 2 else { continue }
                let spot = settle(id, near: p, far: far, in: a)
                if far { a.far[id] = spot } else { a.near[id] = spot }
            }
        }
    }

    private func change(_ project: String, _ body: (inout Arrangement) -> Void) {
        guard var a = arrangements[project] else { return }
        previousArrangement[project] = a
        a.touched = true
        body(&a)
        arrangements[project] = a
        lastChange[project] = Date()
        saveArrangements()
    }

    /// Maps drawn before notes had room under each capture: make that room,
    /// moving captures as little as possible. Once.
    func makeNoteRoom(project: String) {
        guard var a = arrangements[project], a.notesRoom != true else { return }
        let note = noteRoom(a)
        let ids = Array(a.far.keys).sorted()
        var boxes = ids.map { id -> MapBox in
            let p = a.far[id]!, s = artifactSize(id)
            return MapBox(x: p.x, y: p.y + note / 2, width: s.width, height: s.height + note)
        }
        TreeLayout.separate(&boxes, obstacles: a.themes.map { labelBox($0, tier: 1, in: a) }, gap: Self.mapGap, iterations: 300)
        for (i, id) in ids.enumerated() { a.far[id] = MapPoint(x: boxes[i].x, y: boxes[i].y - note / 2) }
        a.notesRoom = true
        arrangements[project] = a
        saveArrangements()
    }

    struct ThemeLinkScore {
        let a: String
        let b: String
        /// 0...1 among the links shown.
        let strength: Double
    }

    /// Which themes share meaning: each theme to the one or two it's most
    /// like, among the closest pairs in the project.
    func themeLinks(project: String) -> [ThemeLinkScore] {
        guard let a = arrangements[project], a.themes.count > 1 else { return [] }
        var centres: [String: [Float]] = [:]
        for theme in a.themes {
            let vs = members(of: theme.key, tier: 1, in: a).compactMap { UUID(uuidString: $0) }.compactMap { vector(for: $0) }
            guard let dim = vs.first?.count else { continue }
            var sum = [Float](repeating: 0, count: dim)
            for v in vs where v.count == dim { for d in 0..<dim { sum[d] += v[d] } }
            centres[theme.key] = sum
        }
        let keys = a.themes.map(\.key).filter { centres[$0] != nil }
        var pairs: [(String, String, Double)] = []
        for i in keys.indices { for j in (i + 1)..<keys.count {
            pairs.append((keys[i], keys[j], Double(cosine(centres[keys[i]]!, centres[keys[j]]!))))
        } }
        guard !pairs.isEmpty else { return [] }
        pairs.sort { $0.2 > $1.2 }
        // Each theme's strongest one or two, and only the closer half of all pairs.
        let cut = pairs[min(pairs.count - 1, max(0, pairs.count / 2))].2
        var degree: [String: Int] = [:]
        var kept: [(String, String, Double)] = []
        for pair in pairs where pair.2 >= cut {
            guard degree[pair.0, default: 0] < 2, degree[pair.1, default: 0] < 2 else { continue }
            kept.append(pair)
            degree[pair.0, default: 0] += 1
            degree[pair.1, default: 0] += 1
        }
        let top = kept.first?.2 ?? 1, low = kept.last?.2 ?? 0
        return kept.map { ThemeLinkScore(a: $0.0, b: $0.1, strength: top > low ? ($0.2 - low) / (top - low) : 1) }
    }

    // MARK: Margin's first draft

    /// Keeps Margin's first sorting as the map's starting point.
    func freeze(project: String, map: ProjectMap, layout r: TreeLayout.Result) {
        let titles = self.titles[project] ?? [:]
        var a = Arrangement(themes: [], patterns: [], themeOf: [:], patternOf: [:], far: r.far, near: r.near,
                            fit: r.fit, ratio: r.ratio, touched: false, notesRoom: true)
        for theme in map.themes {
            a.themes.append(MapGroup(key: theme.key, title: titles[theme.key] ?? "", label: r.themeLabels[theme.key] ?? MapPoint(x: 0, y: 0)))
            for id in theme.members { a.themeOf[id] = theme.key }
        }
        for pattern in map.patterns {
            let parent = pattern.parent.flatMap { map.themes.indices.contains($0) ? map.themes[$0].key : nil }
            a.patterns.append(MapGroup(key: pattern.key, title: titles[pattern.key] ?? "", parent: parent,
                                       label: r.patternLabels[pattern.key] ?? MapPoint(x: 0, y: 0)))
            for id in pattern.members { a.patternOf[id] = pattern.key }
        }
        arrangements[project] = a
        saveArrangements()
    }

    /// Until you change something, Margin's names follow its model as they
    /// arrive. After that they're left alone.
    func followNames(project: String) {
        guard var a = arrangements[project], !a.touched, let titles = titles[project] else { return }
        var changed: Set<String> = []
        for i in a.themes.indices where !a.themes[i].mine {
            if let t = titles[a.themes[i].key], t != a.themes[i].title { a.themes[i].title = t; changed.insert(a.themes[i].key) }
        }
        for i in a.patterns.indices where !a.patterns[i].mine {
            if let t = titles[a.patterns[i].key], t != a.patterns[i].title { a.patterns[i].title = t; changed.insert(a.patterns[i].key) }
        }
        guard !changed.isEmpty else { return }
        clear(&a, far: true, keys: changed)
        clear(&a, far: false, keys: changed)
        arrangements[project] = a
        saveArrangements()
    }

    /// Starts over: Margin sorts the project afresh.
    func resort(project: String) {
        guard let a = arrangements[project] else { return }
        previousArrangement[project] = a
        lastChange[project] = Date()
        edits[project] = nil
        arrangements[project] = nil
        saveArrangements()
    }

    func undo(project: String) {
        guard let before = previousArrangement[project] else { return }
        previousArrangement[project] = nil
        lastChange[project] = nil
        arrangements[project] = before
        saveArrangements()
    }

    // MARK: New captures

    /// New captures settle into the pattern they fit best, at the free spot
    /// nearest it, without moving anything already there.
    func adopt(project: String, entries: [Entry]) {
        guard var a = arrangements[project], !a.patterns.isEmpty else { return }
        let missing = entries.filter { a.patternOf[$0.id.uuidString] == nil }
        guard !missing.isEmpty else { return }
        for entry in missing {
            let id = entry.id.uuidString
            let pattern = bestPattern(for: entry, in: a)
            a.patternOf[id] = pattern.key
            a.themeOf[id] = pattern.parent ?? a.themes.first?.key ?? ""
            let others = members(of: pattern.key, tier: 0, in: a).filter { $0 != id }
            let theme = a.themes.first { $0.key == pattern.parent }
            a.far[id] = settle(id, near: middle(of: others, far: true, in: a) ?? theme?.label ?? pattern.label, far: true, in: a)
            a.near[id] = settle(id, near: middle(of: others, far: false, in: a) ?? pattern.label, far: false, in: a)
        }
        arrangements[project] = a
        saveArrangements()
    }

    private func bestPattern(for entry: Entry, in a: Arrangement) -> MapGroup {
        if let v = vector(for: entry.id) {
            var best: (group: MapGroup, score: Float)?
            for pattern in a.patterns {
                let vs = members(of: pattern.key, tier: 0, in: a).compactMap { UUID(uuidString: $0) }.compactMap { vector(for: $0) }
                guard !vs.isEmpty else { continue }
                var sum = [Float](repeating: 0, count: v.count)
                for w in vs where w.count == v.count { for d in 0..<v.count { sum[d] += w[d] } }
                let score = cosine(v, sum)
                if best == nil || score > best!.score { best = (pattern, score) }
            }
            if let best { return best.group }
        }
        // Without words: with the capture made nearest in time.
        let placed = a.patternOf.compactMap { key, value -> (Date, String)? in
            guard let uuid = UUID(uuidString: key), let other = store.entry(id: uuid) else { return nil }
            return (other.createdAt, value)
        }
        let nearest = placed.min { abs($0.0.timeIntervalSince(entry.createdAt)) < abs($1.0.timeIntervalSince(entry.createdAt)) }
        return a.patterns.first { $0.key == nearest?.1 } ?? a.patterns[0]
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    // MARK: Your changes

    /// Moves a capture to where you dropped it; it joins the group whose
    /// name is nearest. In the other layout it takes the free spot nearest
    /// its new group. Nothing else moves.
    func move(project: String, entry: UUID, to point: MapPoint, far: Bool) {
        moveMany(project: project, moves: [(entry, point)], far: far)
    }

    /// Moves several captures at once (a selection dragged together), as
    /// one change, so one Undo puts them all back.
    func moveMany(project: String, moves: [(UUID, MapPoint)], far: Bool) {
        guard let a0 = arrangements[project], !moves.isEmpty else { return }
        let moving = Set(moves.map { $0.0.uuidString })
        var targets: [(id: String, point: MapPoint, group: MapGroup)] = []
        for (entry, point) in moves {
            let id = entry.uuidString
            func distance(_ p: MapPoint) -> Double { hypot(p.x - point.x, p.y - point.y) }
            var pattern: MapGroup?
            if far {
                guard let theme = a0.themes.min(by: { distance($0.label) < distance($1.label) }) else { continue }
                pattern = a0.patterns.filter { $0.parent == theme.key }.min { p, q in
                    distance(middle(of: members(of: p.key, tier: 0, in: a0).filter { !moving.contains($0) }, far: true, in: a0) ?? theme.label)
                        < distance(middle(of: members(of: q.key, tier: 0, in: a0).filter { !moving.contains($0) }, far: true, in: a0) ?? theme.label)
                }
            } else {
                pattern = a0.patterns.min { distance($0.label) < distance($1.label) }
            }
            if let pattern { targets.append((id, point, pattern)) }
        }
        guard !targets.isEmpty else { return }
        change(project) { a in
            // Lift them all first, so they don't push each other aside.
            for t in targets { a.far[t.id] = nil; a.near[t.id] = nil }
            for t in targets {
                let id = t.id, target = t.group
                a.patternOf[id] = target.key
                a.themeOf[id] = target.parent ?? a.themeOf[id]
                let others = members(of: target.key, tier: 0, in: a).filter { !moving.contains($0) }
                let theme = a.themes.first { $0.key == target.parent }
                if far {
                    a.far[id] = settle(id, near: t.point, far: true, in: a)
                    a.near[id] = settle(id, near: middle(of: others, far: false, in: a) ?? target.label, far: false, in: a)
                } else {
                    a.near[id] = settle(id, near: t.point, far: false, in: a)
                    a.far[id] = settle(id, near: middle(of: others, far: true, in: a) ?? theme?.label ?? target.label, far: true, in: a)
                }
                for i in a.themes.indices { a.themes[i].suggested.removeAll { $0 == id } }
                for i in a.patterns.indices { a.patterns[i].suggested.removeAll { $0 == id } }
            }
        }
    }

    /// Renames a group. Only the name changes.
    func renameGroup(project: String, tier: Int, key: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        change(project) { a in
            if tier == 1, let i = a.themes.firstIndex(where: { $0.key == key }) {
                a.themes[i].title = clean
                a.themes[i].mine = true
            } else if let i = a.patterns.firstIndex(where: { $0.key == key }) {
                a.patterns[i].title = clean
                a.patterns[i].mine = true
            }
            clear(&a, far: tier == 1, keys: [key])
        }
    }

    /// Deletes a group (a theme with its patterns, or one pattern). If it
    /// held captures, each joins the remaining group it fits best, at the
    /// free spot nearest it. The last theme can't be deleted.
    func removeGroup(project: String, tier: Int, key: String) {
        guard let a0 = arrangements[project] else { return }
        let removedPatterns: Set<String> = tier == 1
            ? Set(a0.patterns.filter { $0.parent == key }.map(\.key))
            : [key]
        let leftPatterns = a0.patterns.filter { !removedPatterns.contains($0.key) }
        if tier == 1 {
            guard a0.themes.contains(where: { $0.key == key }), a0.themes.count > 1 else { return }
        } else {
            guard a0.patterns.contains(where: { $0.key == key }) else { return }
        }
        let homeless = a0.patternOf.filter { removedPatterns.contains($0.value) }.map(\.key).sorted()
            + (tier == 1 ? a0.themeOf.filter { $0.value == key && !removedPatterns.contains(a0.patternOf[$0.key] ?? "") }.map(\.key).sorted() : [])
        // Captures need somewhere to go.
        if !homeless.isEmpty && leftPatterns.isEmpty { return }

        change(project) { a in
            if tier == 1 { a.themes.removeAll { $0.key == key } }
            a.patterns.removeAll { removedPatterns.contains($0.key) }
            // A theme left without patterns or captures goes with it.
            if tier == 0, let parent = a0.patterns.first(where: { $0.key == key })?.parent,
               !a.patterns.contains(where: { $0.parent == parent }),
               !a.themeOf.contains(where: { $0.value == parent && !homeless.contains($0.key) }),
               a.themes.count > 1 {
                a.themes.removeAll { $0.key == parent }
            }
            for id in homeless {
                a.patternOf[id] = nil
                a.themeOf[id] = nil
                a.far[id] = nil
                a.near[id] = nil
            }
            for id in homeless {
                guard let uuid = UUID(uuidString: id), let entry = store.entry(id: uuid), !a.patterns.isEmpty else { continue }
                let pattern = bestPattern(for: entry, in: a)
                a.patternOf[id] = pattern.key
                a.themeOf[id] = pattern.parent ?? a.themes.first?.key ?? ""
                let others = members(of: pattern.key, tier: 0, in: a).filter { $0 != id }
                let theme = a.themes.first { $0.key == pattern.parent }
                a.far[id] = settle(id, near: middle(of: others, far: true, in: a) ?? theme?.label ?? pattern.label, far: true, in: a)
                a.near[id] = settle(id, near: middle(of: others, far: false, in: a) ?? pattern.label, far: false, in: a)
            }
        }
    }

    /// A new, empty group where you wrote it. Margin offers the captures
    /// that might fit, and moves nothing.
    func addGroup(project: String, title: String, at point: MapPoint, far: Bool, entries: [Entry]) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let current = arrangements[project] else { return }
        let suggestions = suggest(for: clean, entries: entries)
        change(project) { a in
            if far {
                let key = "mine-\(UUID().uuidString)"
                a.themes.append(MapGroup(key: key, title: clean, mine: true, label: point, suggested: suggestions))
                // Its pattern, for the closer steps: the same name, in the
                // nearest free room there.
                var pattern = MapGroup(key: key + "-p", title: clean, mine: true, parent: key, label: point)
                let box = labelBox(pattern, tier: 0, in: a)
                pattern.label = TreeLayout.freeSpot(near: point, size: MapSize(width: box.width, height: box.height),
                                                    avoiding: obstacles(a, far: false), gap: Self.mapGap * 2, step: 16)
                a.patterns.append(pattern)
                clear(&a, far: true, keys: [key])
            } else {
                let nearest = current.patterns.min { hypot($0.label.x - point.x, $0.label.y - point.y) < hypot($1.label.x - point.x, $1.label.y - point.y) }
                let key = "mine-\(UUID().uuidString)"
                a.patterns.append(MapGroup(key: key, title: clean, mine: true, parent: nearest?.parent ?? a.themes.first?.key,
                                           label: point, suggested: suggestions))
                clear(&a, far: false, keys: [key])
            }
        }
    }

    /// The captures that read most like a headline: offered, not moved.
    private func suggest(for title: String, entries: [Entry]) -> [String] {
        guard let v = Embedder.embedOne(title) else { return [] }
        let scored = entries.compactMap { e -> (String, Float)? in
            guard let w = vector(for: e.id) else { return nil }
            return (e.id.uuidString, cosine(v, w))
        }.sorted { $0.1 > $1.1 }
        guard let top = scored.first?.1, top > 0.3 else { return [] }
        return scored.prefix(6).filter { $0.1 >= max(0.3, top * 0.85) }.map { $0.0 }
    }

    /// Takes Margin's suggestion: those captures join the group, each at
    /// the free spot nearest it.
    func acceptSuggestions(project: String, tier: Int, key: String, only: String? = nil) {
        guard let a0 = arrangements[project] else { return }
        let group = (tier == 1 ? a0.themes : a0.patterns).first { $0.key == key }
        guard let group, !group.suggested.isEmpty else { return }
        let taking = only.map { [$0] } ?? group.suggested
        let pattern = tier == 1 ? a0.patterns.first { $0.parent == key } : group
        guard let pattern else { return }
        let theme = a0.themes.first { $0.key == (tier == 1 ? key : pattern.parent) }
        change(project) { a in
            for id in taking {
                a.patternOf[id] = pattern.key
                a.themeOf[id] = theme?.key ?? a.themeOf[id]
                a.far[id] = nil
                a.near[id] = nil
                let others = members(of: pattern.key, tier: 0, in: a).filter { $0 != id }
                a.far[id] = settle(id, near: middle(of: others, far: true, in: a) ?? theme?.label ?? pattern.label, far: true, in: a)
                a.near[id] = settle(id, near: middle(of: others, far: false, in: a) ?? pattern.label, far: false, in: a)
            }
            if tier == 1, let i = a.themes.firstIndex(where: { $0.key == key }) { a.themes[i].suggested.removeAll { taking.contains($0) } }
            if tier == 0, let i = a.patterns.firstIndex(where: { $0.key == key }) { a.patterns[i].suggested.removeAll { taking.contains($0) } }
        }
    }

    func dismissSuggestions(project: String, tier: Int, key: String) {
        guard var a = arrangements[project] else { return }
        if tier == 1, let i = a.themes.firstIndex(where: { $0.key == key }) { a.themes[i].suggested = [] }
        if tier == 0, let i = a.patterns.firstIndex(where: { $0.key == key }) { a.patterns[i].suggested = [] }
        arrangements[project] = a
        saveArrangements()
    }
}
