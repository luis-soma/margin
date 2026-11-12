import Foundation

/// One capture, as the map reads it: what it means (a vector from its words
/// and what Margin saw), when it was made, and where it came from.
public struct MapItem {
    public var id: String
    /// Unit length, or nil when the capture has nothing to read yet.
    public var vector: [Float]?
    public var date: Date
    /// Where it came from (a file, a conversation, an app), for captures
    /// without words: they sit with their neighbours from the same place.
    public var source: String?
    /// Changes when what the vector was read from changes.
    public var version: String

    public init(id: String, vector: [Float]?, date: Date, source: String? = nil, version: String = "") {
        self.id = id
        self.vector = vector
        self.date = date
        self.source = source
        self.version = version
    }
}

public struct MapPoint: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A headline the designer gave the map: a name they wrote, or a group
/// they steered by dropping captures into it. Margin sorts captures into
/// it by meaning and keeps it whatever else changes.
public struct MapHeadline: Codable, Equatable {
    public var id: String
    /// 1 a theme, 0 a pattern inside a theme.
    public var tier: Int
    /// The designer's words; nil when only the group was steered and Margin
    /// still names it.
    public var title: String?
    /// For a pattern: the theme headline it sits in.
    public var parent: String?
    /// The captures the group had when the designer took it over: they
    /// keep it close to what it was.
    public var anchors: [String]
    /// The title read into a vector, for sorting captures into it.
    public var vector: [Float]?

    public init(id: String, tier: Int, title: String?, parent: String? = nil, anchors: [String] = [], vector: [Float]? = nil) {
        self.id = id
        self.tier = tier
        self.title = title
        self.parent = parent
        self.anchors = anchors
        self.vector = vector
    }
}

/// Everything the designer changed on a project's map.
public struct MapEdits: Codable, Equatable {
    public var headlines: [MapHeadline]
    /// Captures put in a group by hand: capture id to headline id.
    public var placed: [String: String]

    public init(headlines: [MapHeadline] = [], placed: [String: String] = [:]) {
        self.headlines = headlines
        self.placed = placed
    }

    public var signature: String {
        var hash = FNV()
        for h in headlines.sorted(by: { $0.id < $1.id }) {
            hash.add(h.id); hash.add("\(h.tier)"); hash.add(h.title ?? "-"); hash.add(h.parent ?? "-")
            hash.add(h.anchors.sorted().joined(separator: ","))
        }
        for key in placed.keys.sorted() { hash.add(key); hash.add(placed[key]!) }
        return hash.hex
    }

    public func headline(_ id: String) -> MapHeadline? { headlines.first { $0.id == id } }
}

/// A project grouped by meaning: the themes running through it and the
/// patterns inside each theme. The designer's headlines are kept and the
/// rest is Margin's reading.
public struct ProjectMap: Equatable {
    public struct Cluster: Equatable {
        /// Stable while it's the same group: the headline's id for the
        /// designer's groups, a hash of the members for Margin's.
        public var key: String
        /// Closest to the middle of the group first.
        public var members: [String]
        /// For a pattern: the index of its theme. For a theme: nil.
        public var parent: Int?
        /// For a theme: its patterns, most alike side by side.
        public var children: [Int]
        /// The designer's headline, when it's theirs.
        public var headline: String?

        public init(key: String, members: [String], parent: Int?, children: [Int] = [], headline: String? = nil) {
            self.key = key
            self.members = members
            self.parent = parent
            self.children = children
            self.headline = headline
        }
    }

    /// tiers[0] the patterns, tiers[1] the themes.
    public var tiers: [[Cluster]]
    /// Each capture's closest captures by meaning, closest first.
    public var neighbors: [String: [String]]
    /// How alike each of those is to it (cosine), in the same order.
    public var neighborSimilarity: [String: [Double]]
    /// How alike each pair of themes is, 0...1.
    public var themeAffinity: [[Double]]
    /// Which captures, vectors and edits this was built from.
    public var signature: String

    public init(tiers: [[Cluster]], neighbors: [String: [String]], neighborSimilarity: [String: [Double]] = [:],
                themeAffinity: [[Double]], signature: String) {
        self.tiers = tiers
        self.neighbors = neighbors
        self.neighborSimilarity = neighborSimilarity
        self.themeAffinity = themeAffinity
        self.signature = signature
    }

    public var patterns: [Cluster] { tiers[0] }
    public var themes: [Cluster] { tiers[1] }

    /// Same captures, vectors and edits: same map.
    public static func signature(of items: [MapItem], edits: MapEdits) -> String {
        var hash = FNV()
        hash.add("map-4")
        for item in items.sorted(by: { $0.id < $1.id }) {
            hash.add(item.id)
            hash.add(item.vector == nil ? "-" : "v\(item.vector!.count)")
            hash.add(item.version)
        }
        hash.add(edits.signature)
        return "\(items.count)-\(hash.hex)"
    }

    /// A short hash that stays the same from launch to launch.
    public static func stableHash(_ text: String) -> String {
        var hash = FNV()
        hash.add(text)
        return hash.hex
    }

    public static func clusterKey(_ members: [String]) -> String {
        var hash = FNV()
        for id in members.sorted() { hash.add(id) }
        return hash.hex
    }
}

/// Builds the groups. Pure and deterministic: the same captures and edits
/// always give the same groups, so it can run in the background whenever
/// something changes, and nothing but names ever needs the network.
public enum ProjectMapBuilder {
    public static func build(_ input: [MapItem], edits: MapEdits = MapEdits()) -> ProjectMap {
        let items = input.sorted { $0.date < $1.date }
        let n = items.count
        let signature = ProjectMap.signature(of: items, edits: edits)
        guard n > 0 else { return ProjectMap(tiers: [[], []], neighbors: [:], themeAffinity: [], signature: signature) }
        let ids = items.map(\.id)
        var index: [String: Int] = [:]
        for (i, id) in ids.enumerated() { index[id] = i }

        let vectors = fillVectors(items)
        let dim = vectors.first?.count ?? 0
        func fits(_ v: [Float]?) -> [Float]? { v.flatMap { $0.count == dim ? normalized($0) : nil } }

        // The designer's headlines, in an order that doesn't change.
        let themeHeads = edits.headlines.filter { $0.tier == 1 }.sorted { $0.id < $1.id }
        let patternHeads = edits.headlines.filter { $0.tier == 0 }.sorted { $0.id < $1.id }
        var themeOfHead: [String: Int] = [:]
        for (t, h) in themeHeads.enumerated() { themeOfHead[h.id] = t }

        // Captures placed by hand, and the anchors of each headline.
        func handPlaced(in headline: String) -> [Int] {
            edits.placed.compactMap { key, value in value == headline ? index[key] : nil }
        }
        func base(of h: MapHeadline, extra: [Int]) -> [Float]? {
            let anchorMembers = h.anchors.compactMap { index[$0] } + extra
            let anchorVec = anchorMembers.isEmpty ? nil : centroid(anchorMembers, vectors)
            let titleVec = fits(h.vector)
            switch (titleVec, anchorVec) {
            case let (t?, a?): return normalized(zip(t, a).map { $0 * 0.8 + $1 })
            case let (t?, nil): return t
            case let (nil, a?): return a
            default: return nil
            }
        }

        // 1. Themes.
        var themeHard: [Int: Int] = [:]
        for (key, value) in edits.placed {
            guard let i = index[key] else { continue }
            if let t = themeOfHead[value] {
                themeHard[i] = t
            } else if let p = edits.headline(value), p.tier == 0, let parent = p.parent, let t = themeOfHead[parent] {
                themeHard[i] = t
            }
        }
        let themeBases: [[Float]?] = themeHeads.map { h in
            let fromPatterns = patternHeads.filter { $0.parent == h.id }.flatMap { handPlaced(in: $0.id) }
            return base(of: h, extra: handPlaced(in: h.id) + fromPatterns)
        }
        // At most five themes: enough to tell the story, few enough to read at a glance.
        let target = n < 6 ? 1 : min(5, max(2, Int((Double(n) / 3).squareRoot().rounded())))
        let freeThemes = max(themeHeads.isEmpty ? target : 0, target - themeHeads.count)
        let themeGroups = constrainedGroups(Array(0..<n), fixed: themeBases, free: freeThemes, hard: themeHard, vectors: vectors)

        // 2. Patterns inside each theme.
        var patterns: [ProjectMap.Cluster] = []
        var themes: [ProjectMap.Cluster] = []
        for (t, group) in themeGroups.enumerated() {
            let themeHead = group.fixed.map { themeHeads[$0].id }
            // The designer's patterns in this theme: those under its headline,
            // or (without one) those whose captures mostly landed here.
            let mine = patternHeads.filter { p in
                if let parent = p.parent, themeOfHead[parent] != nil { return parent == themeHead }
                let theirs = (p.anchors.compactMap { index[$0] } + handPlaced(in: p.id))
                let here = Set(group.members)
                return !theirs.isEmpty && theirs.filter { here.contains($0) }.count * 2 >= theirs.count
            }
            var hard: [Int: Int] = [:]
            for (pi, p) in mine.enumerated() { for i in handPlaced(in: p.id) where group.members.contains(i) { hard[i] = pi } }
            let bases = mine.map { base(of: $0, extra: handPlaced(in: $0.id)) }
            let want = min(4, max(1, Int((Double(group.members.count) / 7).rounded())))
            let free = max(mine.isEmpty ? want : 0, want - mine.count)
            let subgroups = constrainedGroups(group.members, fixed: bases, free: free, hard: hard, vectors: vectors)

            var childIndices: [Int] = []
            var childVectors: [[Float]] = []
            for sub in subgroups {
                let ordered = byCloseness(sub.members, vectors)
                let headline = sub.fixed.map { mine[$0].id }
                let memberIDs = ordered.map { ids[$0] }
                childIndices.append(patterns.count)
                childVectors.append(centroid(sub.members.isEmpty ? group.members : sub.members, vectors))
                patterns.append(ProjectMap.Cluster(key: headline.map { "h:\($0)" } ?? ProjectMap.clusterKey(memberIDs),
                                                   members: memberIDs, parent: t, headline: headline))
            }
            let chain = similarityChain(childVectors, sizes: subgroups.map(\.members.count))
            let ordered = byCloseness(group.members, vectors).map { ids[$0] }
            themes.append(ProjectMap.Cluster(key: themeHead.map { "h:\($0)" } ?? ProjectMap.clusterKey(ordered),
                                             members: ordered, parent: nil, children: chain.map { childIndices[$0] }, headline: themeHead))
        }

        // 3. How alike the themes are, for where they sit.
        let themeVectors = themeGroups.map { centroid($0.members.isEmpty ? Array(0..<n) : $0.members, vectors) }
        let affinity = themeVectors.map { a in themeVectors.map { b in Double(max(0, dot(a, b))) } }

        // 4. Closest captures by meaning, for the lines on hover and for
        // what follows a capture you move.
        var neighbors: [String: [String]] = [:]
        var neighborSimilarity: [String: [Double]] = [:]
        if n > 1 {
            for i in 0..<n {
                let others = (0..<n).filter { $0 != i }.map { ($0, dot(vectors[i], vectors[$0])) }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                neighbors[ids[i]] = others.prefix(3).map { ids[$0.0] }
                neighborSimilarity[ids[i]] = others.prefix(3).map { Double($0.1) }
            }
        }
        return ProjectMap(tiers: [patterns, themes], neighbors: neighbors, neighborSimilarity: neighborSimilarity,
                          themeAffinity: affinity, signature: signature)
    }

    // MARK: Vectors

    static func fillVectors(_ items: [MapItem]) -> [[Float]] {
        let n = items.count
        let dim = items.compactMap(\.vector).first?.count ?? 0
        guard dim > 0 else {
            // Nothing to read anywhere: group by where captures came from,
            // and otherwise by time.
            var places: [String: Int] = [:]
            for item in items { if places[item.source ?? ""] == nil { places[item.source ?? ""] = places.count } }
            let size = max(places.count, 1) + 4
            return items.enumerated().map { index, item in
                var v = [Float](repeating: 0, count: size)
                v[places[item.source ?? ""] ?? 0] = 1
                v[places.count + min(3, index * 4 / max(n, 1))] = 0.5
                return normalized(v)
            }
        }
        var result = items.map { $0.vector?.count == dim ? normalized($0.vector!) : nil as [Float]? }
        for i in 0..<n where result[i] == nil {
            var found: [Float]?
            // Same place first, then anything, nearest in time.
            for sameSource in [true, false] {
                var step = 1
                while found == nil, step < n {
                    for j in [i - step, i + step] where j >= 0 && j < n {
                        guard found == nil, let v = items[j].vector, v.count == dim else { continue }
                        if !sameSource || (items[j].source != nil && items[j].source == items[i].source) { found = v }
                    }
                    step += 1
                }
                if found != nil { break }
            }
            result[i] = normalized(found ?? [Float](repeating: 1, count: dim))
        }
        return result.map { $0! }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var length: Float = 0
        for x in v { length += x * x }
        length = length.squareRoot()
        guard length > 0 else { return v }
        return v.map { $0 / length }
    }

    static func centroid(_ members: [Int], _ vectors: [[Float]]) -> [Float] {
        guard let dim = vectors.first?.count, !members.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: dim)
        for i in members { for d in 0..<dim { sum[d] += vectors[i][d] } }
        return normalized(sum)
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for d in 0..<min(a.count, b.count) { s += a[d] * b[d] }
        return s
    }

    static func byCloseness(_ members: [Int], _ vectors: [[Float]]) -> [Int] {
        let middle = centroid(members, vectors)
        return members.sorted { a, b in
            let da = dot(vectors[a], middle), db = dot(vectors[b], middle)
            return da != db ? da > db : a < b
        }
    }

    /// The biggest first, then always the most alike not yet chosen, so
    /// neighbours in the list are alike.
    static func similarityChain(_ vectors: [[Float]], sizes: [Int]) -> [Int] {
        guard !vectors.isEmpty else { return [] }
        var order = [sizes.indices.max { sizes[$0] < sizes[$1] }!]
        while order.count < vectors.count {
            let last = order.last!
            let next = vectors.indices.filter { !order.contains($0) }.max { dot(vectors[last], vectors[$0]) < dot(vectors[last], vectors[$1]) }!
            order.append(next)
        }
        return order
    }

    // MARK: Groups

    struct Group {
        var members: [Int]
        /// The index of the designer's headline this group is, if it is one.
        var fixed: Int?
    }

    /// Sorts captures into the designer's headlines (each pulled toward its
    /// title and its captures) and `free` groups of Margin's own (spherical
    /// k-means), with room in each capped so none takes most of the
    /// captures. Captures placed by hand stay put. Margin's groups too small
    /// to stand alone fold into the closest group; the designer's are kept,
    /// even empty. Deterministic.
    static func constrainedGroups(_ members: [Int], fixed: [[Float]?], free freeWanted: Int,
                                  hard: [Int: Int], vectors: [[Float]]) -> [Group] {
        let m = members.count
        let fixedCount = fixed.count
        let free = fixedCount + freeWanted <= 1 ? (fixedCount == 0 ? 1 : 0) : min(freeWanted, max(0, m / 2 - fixedCount))
        let k = fixedCount + free
        guard k > 0 else { return [Group(members: members, fixed: nil)] }
        guard m > 0 else { return (0..<fixedCount).map { Group(members: [], fixed: $0) } }
        if k == 1 { return [Group(members: members, fixed: fixedCount == 1 ? 0 : nil)] }

        let middle = centroid(members, vectors)
        let bases: [[Float]] = fixed.map { $0 ?? middle }
        var centres: [[Float]] = bases
        // Starting centres for Margin's groups: farthest-point.
        let open = members.filter { hard[$0] == nil }
        var pool = open.isEmpty ? members : open
        if centres.isEmpty {
            let first = pool.max { dot(vectors[$0], middle) < dot(vectors[$1], middle) }!
            centres.append(vectors[first])
            pool.removeAll { $0 == first }
        }
        while centres.count < k, !pool.isEmpty {
            let next = pool.min { a, b in
                centres.map { dot(vectors[a], $0) }.max()! < centres.map { dot(vectors[b], $0) }.max()!
            }!
            centres.append(vectors[next])
            pool.removeAll { $0 == next }
        }
        let groupCount = centres.count

        let capacity = Int((Double(m) / Double(groupCount) * 1.6).rounded(.up))
        var owner = [Int](repeating: 0, count: m)
        for _ in 0..<16 {
            let scores = members.map { i in centres.map { dot(vectors[i], $0) } }
            let order = (0..<m).sorted { a, b in
                let sa = scores[a].sorted(by: >), sb = scores[b].sorted(by: >)
                let ma = sa[0] - (sa.count > 1 ? sa[1] : 0), mb = sb[0] - (sb.count > 1 ? sb[1] : 0)
                return ma != mb ? ma > mb : a < b
            }
            var load = [Int](repeating: 0, count: groupCount)
            var next = owner
            for p in 0..<m { if let h = hard[members[p]], h < groupCount { next[p] = h; load[h] += 1 } }
            for p in order where hard[members[p]] == nil || hard[members[p]]! >= groupCount {
                let ranked = (0..<groupCount).sorted { scores[p][$0] != scores[p][$1] ? scores[p][$0] > scores[p][$1] : $0 < $1 }
                let pick = ranked.first { load[$0] < capacity } ?? ranked[0]
                next[p] = pick
                load[pick] += 1
            }
            let changed = next != owner
            owner = next
            for c in 0..<groupCount {
                let inGroup = (0..<m).filter { owner[$0] == c }.map { members[$0] }
                if c < fixedCount {
                    // The designer's groups stay true to their title and captures.
                    if !inGroup.isEmpty { centres[c] = normalized(zip(bases[c], centroid(inGroup, vectors)).map { $0 + $1 * 0.6 }) }
                } else if !inGroup.isEmpty {
                    centres[c] = centroid(inGroup, vectors)
                }
            }
            if !changed { break }
        }

        // Fold Margin's groups too small to stand alone into the closest group.
        let smallest = max(2, m / (groupCount * 3))
        var groups = (0..<groupCount).map { c in (0..<m).filter { owner[$0] == c } }
        while true {
            let alive = groups.indices.filter { !groups[$0].isEmpty || $0 < fixedCount }
            guard alive.count > 1,
                  let small = groups.indices.filter({ $0 >= fixedCount && !groups[$0].isEmpty && groups[$0].count < smallest })
                    .min(by: { groups[$0].count < groups[$1].count }) else { break }
            let others = alive.filter { $0 != small }
            for p in groups[small] {
                let best = others.max { dot(vectors[members[p]], centres[$0]) < dot(vectors[members[p]], centres[$1]) }!
                groups[best].append(p)
            }
            groups[small] = []
        }
        var result: [Group] = []
        for c in 0..<groupCount where c < fixedCount || !groups[c].isEmpty {
            result.append(Group(members: groups[c].map { members[$0] }.sorted(), fixed: c < fixedCount ? c : nil))
        }
        return result
    }
}

/// A small, stable string hash (FNV-1a, 64 bit).
struct FNV {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        value ^= 0xFF
        value = value &* 0x0000_0100_0000_01B3
    }

    var hex: String { String(value, radix: 16) }
}
