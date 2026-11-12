import Foundation

/// A box on the map by its centre, for keeping things apart.
public struct MapBox: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct MapSize: Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Lays a project's groups out like a tree seen from above: each theme's
/// name with its patterns branching round it, each pattern's name with its
/// captures round it like leaves, the most telling ones nearest. Themes
/// scatter across the window with plenty of air between them. Nothing ever
/// overlaps: no capture on a capture, none on a name, no name on a name.
///
/// Names keep one size on screen whatever the zoom, so the room a name
/// needs on the map depends on the zoom it's read at. There are two
/// layouts: the big picture, with room for the themes' names, and the
/// closer steps, with room for the patterns' names and your notes. The
/// view glides between them.
public enum TreeLayout {
    public struct Input {
        public var map: ProjectMap
        /// Each capture's size on the map.
        public var sizes: [String: MapSize]
        /// The room each name takes on screen (with its margin), by cluster key.
        public var themeLabels: [String: MapSize]
        public var patternLabels: [String: MapSize]
        /// The window, on screen.
        public var window: MapSize
        /// How large the longest side of a capture should be on screen at the close-up.
        public var closeSide: Double
        /// The longest side of a capture on the map.
        public var side: Double
        /// Room under each capture for its note at the close-up, on screen.
        public var noteHeight: Double

        public init(map: ProjectMap, sizes: [String: MapSize], themeLabels: [String: MapSize], patternLabels: [String: MapSize],
                    window: MapSize, closeSide: Double, side: Double, noteHeight: Double) {
            self.map = map
            self.sizes = sizes
            self.themeLabels = themeLabels
            self.patternLabels = patternLabels
            self.window = window
            self.closeSide = closeSide
            self.side = side
            self.noteHeight = noteHeight
        }
    }

    public struct Result: Equatable {
        /// Centre of each capture at the big picture, and at the closer steps.
        public var far: [String: MapPoint]
        public var near: [String: MapPoint]
        /// Centre of each theme's name (big picture) and pattern's name (closer).
        public var themeLabels: [String: MapPoint]
        public var patternLabels: [String: MapPoint]
        /// The zoom that shows the whole big picture, and how much closer each step goes.
        public var fit: Double
        public var ratio: Double
        /// The middle of the big picture.
        public var centre: MapPoint
    }

    static let gap = 18.0

    public static func layout(_ input: Input) -> Result {
        var fit = 0.5
        var ratio = ratioFor(fit, input)
        var far = place(input, fit: fit, ratio: ratio, far: true)
        // The names' room depends on the zoom that fits, which depends on
        // the room: settle it in a few rounds.
        for _ in 0..<4 {
            let next = fitting(far.extent, input.window)
            if abs(next - fit) / fit < 0.02 { break }
            fit = next
            ratio = ratioFor(fit, input)
            far = place(input, fit: fit, ratio: ratio, far: true)
        }
        fit = min(fit, fitting(far.extent, input.window))
        let near = place(input, fit: fit, ratio: ratio, far: false)
        let e = far.extent
        return Result(far: far.points, near: near.points, themeLabels: far.themeLabels, patternLabels: near.patternLabels,
                      fit: fit, ratio: ratio, centre: MapPoint(x: (e.minX + e.maxX) / 2, y: (e.minY + e.maxY) / 2))
    }

    static func ratioFor(_ fit: Double, _ input: Input) -> Double {
        let close = input.closeSide / input.side
        return min(2.3, max(1.25, pow(close / fit, 1.0 / 3.0)))
    }

    static func fitting(_ e: (minX: Double, minY: Double, maxX: Double, maxY: Double), _ window: MapSize) -> Double {
        let w = max(e.maxX - e.minX, 1), h = max(e.maxY - e.minY, 1)
        return max(0.02, min(1.5, min((window.width - 96) / w, (window.height - 130) / h)))
    }

    struct Placed {
        var points: [String: MapPoint] = [:]
        var themeLabels: [String: MapPoint] = [:]
        var patternLabels: [String: MapPoint] = [:]
        var extent: (minX: Double, minY: Double, maxX: Double, maxY: Double) = (0, 0, 0, 0)
    }

    struct Node {
        /// Offsets from the node's centre.
        var boxes: [(id: String, box: MapBox)]
        var radius: Double
        var label: MapSize
    }

    static func place(_ input: Input, fit: Double, ratio: Double, far: Bool) -> Placed {
        let map = input.map
        let themeZoom = fit, patternZoom = fit * ratio, closeZoom = fit * pow(ratio, 3)
        let note = input.noteHeight / closeZoom
        func size(_ id: String) -> MapSize { input.sizes[id] ?? MapSize(width: input.side, height: input.side * 0.7) }

        var result = Placed()
        var themeFlowers: [(boxes: [(id: String, box: MapBox)], radius: Double, label: MapSize, patterns: [(key: String, x: Double, y: Double)])] = []
        for theme in map.themes {
            let children = theme.children.filter { map.patterns.indices.contains($0) }.map { map.patterns[$0] }
            if far {
                // The theme's name in the middle, its captures round it, each
                // pattern a wedge of them.
                let screen = input.themeLabels[theme.key] ?? MapSize(width: 0, height: 0)
                let label = MapSize(width: screen.width / themeZoom, height: screen.height / themeZoom)
                let groups = children.map { $0.members.map { (id: $0, size: size($0)) } }
                let f = flower(groups, label: label, key: theme.key, note: note, side: input.side)
                themeFlowers.append((boxes: f.boxes, radius: f.radius, label: label, patterns: []))
            } else {
                // Each pattern its own little flower round its name; the
                // patterns of a theme packed together.
                var flowers: [(boxes: [(id: String, box: MapBox)], radius: Double, key: String)] = []
                for pattern in children {
                    let screen = input.patternLabels[pattern.key] ?? MapSize(width: 0, height: 0)
                    let label = MapSize(width: screen.width / patternZoom, height: screen.height / patternZoom)
                    let f = flower([pattern.members.map { (id: $0, size: size($0)) }], label: label, key: pattern.key, note: note, side: input.side)
                    flowers.append((boxes: f.boxes, radius: f.radius, key: pattern.key))
                }
                let spots = pack(flowers.map { $0.radius }, gap: 34, key: theme.key)
                var boxes: [(id: String, box: MapBox)] = []
                var radius = 40.0
                var patterns: [(key: String, x: Double, y: Double)] = []
                for (k, flower) in flowers.enumerated() {
                    let spot = spots[k]
                    patterns.append((key: flower.key, x: spot.x, y: spot.y))
                    radius = max(radius, hypot(spot.x, spot.y) + flower.radius)
                    for item in flower.boxes {
                        var b = item.box
                        b.x += spot.x
                        b.y += spot.y
                        boxes.append((id: item.id, box: b))
                    }
                }
                themeFlowers.append((boxes: boxes, radius: radius, label: MapSize(width: 0, height: 0), patterns: patterns))
            }
        }

        // The themes packed close, wide like the window.
        let spots = pack(themeFlowers.map { $0.radius }, gap: far ? 40 : 60, key: "themes")
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func grow(_ b: MapBox) {
            minX = min(minX, b.x - b.width / 2); maxX = max(maxX, b.x + b.width / 2)
            minY = min(minY, b.y - b.height / 2); maxY = max(maxY, b.y + b.height / 2)
        }
        for (t, theme) in map.themes.enumerated() where t < themeFlowers.count {
            let origin = spots[t]
            let flower = themeFlowers[t]
            result.themeLabels[theme.key] = MapPoint(x: origin.x, y: origin.y)
            if far, flower.label.width > 0 {
                grow(MapBox(x: origin.x, y: origin.y, width: flower.label.width, height: flower.label.height))
            }
            for pattern in flower.patterns {
                result.patternLabels[pattern.key] = MapPoint(x: origin.x + pattern.x, y: origin.y + pattern.y)
            }
            for item in flower.boxes {
                let x = origin.x + item.box.x, y = origin.y + item.box.y
                grow(MapBox(x: x, y: y, width: item.box.width, height: item.box.height))
                // The capture sits at the top of its box, its note under it.
                result.points[item.id] = MapPoint(x: x, y: y - note / 2)
            }
        }
        if minX.isFinite { result.extent = (minX, minY, maxX, maxY) }
        return result
    }

    /// Captures gathered round a name the way things settle round a
    /// centre: one by one, each into the free spot nearest the name, the most
    /// telling first, so they hug the words without lining up. Each pattern
    /// leans its own way round the name, so its captures stay together.
    /// Nothing overlaps.
    static func flower(_ groups: [[(id: String, size: MapSize)]], label: MapSize, key: String, note: Double, side: Double)
        -> (boxes: [(id: String, box: MapBox)], radius: Double) {
        let gap = 10.0
        let total = groups.reduce(0) { $0 + $1.count }
        guard total > 0 else { return ([], max(hypot(label.width, label.height) / 2, 30)) }
        let turn = seed("flower-\(key)").0 * 2 * Double.pi
        var directions: [Double] = []
        var before = 0
        for group in groups {
            directions.append(turn + 2 * Double.pi * (Double(before) + Double(group.count) / 2) / Double(total))
            before += group.count
        }

        // Spots to try, spiralling out from the name, nearest first.
        let step = side * 0.2
        let reach = hypot(label.width, label.height) / 2 + (side + note) * 2.2 * Double(total).squareRoot() + side * 2
        let count = min(60_000, Int(pow(reach / step, 2)) + 200)
        var spots: [(x: Double, y: Double, r: Double)] = []
        spots.reserveCapacity(count)
        for k in 0..<count {
            let r = step * Double(k).squareRoot()
            let a = Double(k) * 2.39996 + turn
            spots.append((r * cos(a) * 1.25, r * sin(a), r))
        }

        // The groups take turns, so they grow together.
        var order: [(group: Int, id: String, size: MapSize)] = []
        var next = [Int](repeating: 0, count: groups.count)
        while order.count < total {
            for (g, group) in groups.enumerated() where next[g] < group.count {
                order.append((group: g, id: group[next[g]].id, size: group[next[g]].size))
                next[g] += 1
            }
        }

        var boxes: [MapBox] = []
        var ids: [String] = []
        for (n, item) in order.enumerated() {
            let w = item.size.width, h = item.size.height + note
            var best: (score: Double, x: Double, y: Double)?
            var seen = 0
            for (k, spot) in spots.enumerated() {
                if abs(spot.x) < (label.width + w) / 2 + gap / 2, abs(spot.y) < (label.height + h) / 2 + gap / 2 { continue }
                if boxes.contains(where: { abs(spot.x - $0.x) < (w + $0.width) / 2 + gap && abs(spot.y - $0.y) < (h + $0.height) / 2 + gap }) { continue }
                let away = groups.count > 1 ? abs(remainder(atan2(spot.y, spot.x) - directions[item.group], 2 * Double.pi)) : 0
                // A little chance in it, so it reads as gathered, not sorted.
                let chance = (sin(Double(k) * 12.9898 + Double(n) * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
                let score = spot.r * (1 + 0.55 * away) + abs(chance) * side * 0.5
                if best == nil || score < best!.score { best = (score, spot.x, spot.y) }
                seen += 1
                if seen > 60 { break }
            }
            let place = best ?? (score: 0, x: reach + side * Double(n), y: 0)
            boxes.append(MapBox(x: place.x, y: place.y, width: w, height: h))
            ids.append(item.id)
        }
        var radius = hypot(label.width, label.height) / 2
        for b in boxes { radius = max(radius, hypot(abs(b.x) + b.width / 2, abs(b.y) + b.height / 2)) }
        return (zip(ids, boxes).map { (id: $0, box: $1) }, max(radius, 30))
    }

    /// Circles packed close round the middle, wider than tall like a window,
    /// never touching. Deterministic.
    static func pack(_ radii: [Double], gap: Double, key: String) -> [(x: Double, y: Double)] {
        let n = radii.count
        guard n > 1 else { return Array(repeating: (0, 0), count: n) }
        let average = radii.reduce(0, +) / Double(n)
        let turn = seed("pack-\(key)").0 * 2 * Double.pi
        var pos = (0..<n).map { i -> (x: Double, y: Double) in
            let a = Double(i) * 2.39996 + turn
            let r = average * 1.2 * (Double(i) + 0.3).squareRoot()
            return (r * cos(a) * 1.5, r * sin(a) * 0.9)
        }
        let steps = 400
        for step in 0..<steps {
            let heat = 1 - Double(step) / Double(steps)
            var force = [(x: Double, y: Double)](repeating: (0, 0), count: n)
            for i in 0..<n {
                force[i].x -= pos[i].x * 0.01
                force[i].y -= pos[i].y * 0.02
                for j in (i + 1)..<n {
                    let want = radii[i] + radii[j] + gap
                    var dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y
                    var d = hypot(dx, dy)
                    if d < 0.01 { dx = 0.3; dy = 0.2; d = 0.36 }
                    guard d < want else { continue }
                    let push = (want - d) / d * 0.4
                    force[i].x -= dx * push; force[i].y -= dy * push
                    force[j].x += dx * push; force[j].y += dy * push
                }
            }
            let limit = 60 * heat + 2
            for i in 0..<n {
                var fx = force[i].x, fy = force[i].y
                let f = hypot(fx, fy)
                if f > limit { fx *= limit / f; fy *= limit / f }
                pos[i].x += fx
                pos[i].y += fy
            }
        }
        // Never touching.
        for _ in 0..<400 {
            var clear = true
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let want = radii[i] + radii[j] + gap * 0.75
                    let dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y
                    let d = max(hypot(dx, dy), 0.01)
                    guard d < want else { continue }
                    clear = false
                    let push = (want - d) / d / 2
                    pos[i].x -= dx * push; pos[i].y -= dy * push
                    pos[j].x += dx * push; pos[j].y += dy * push
                }
            }
            if clear { break }
        }
        return pos
    }

    static func circleHitsBox(_ cx: Double, _ cy: Double, _ r: Double, _ box: MapSize) -> Bool {
        let px = max(-box.width / 2, min(cx, box.width / 2))
        let py = max(-box.height / 2, min(cy, box.height / 2))
        return hypot(cx - px, cy - py) < r
    }

    /// Moves boxes the least it can until none overlaps another (with `gap`
    /// between them) or any of the `obstacles` (the names).
    public static func separate(_ boxes: inout [MapBox], obstacles: [MapBox] = [], gap: Double, iterations: Int = 200) {
        let n = boxes.count
        for round in 0..<iterations {
            var moved = false
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let a = boxes[i], b = boxes[j]
                    let dx = b.x - a.x, dy = b.y - a.y
                    let ox = (a.width + b.width) / 2 + gap - abs(dx)
                    let oy = (a.height + b.height) / 2 + gap - abs(dy)
                    guard ox > 0, oy > 0 else { continue }
                    moved = true
                    if ox < oy {
                        let s: Double = dx > 0 || (dx == 0 && (i + round) % 2 == 0) ? 1 : -1
                        boxes[i].x -= s * ox / 2
                        boxes[j].x += s * ox / 2
                    } else {
                        let s: Double = dy > 0 || (dy == 0 && (i + round) % 2 == 0) ? 1 : -1
                        boxes[i].y -= s * oy / 2
                        boxes[j].y += s * oy / 2
                    }
                }
            }
            for i in 0..<n {
                for o in obstacles {
                    let a = boxes[i]
                    let dx = a.x - o.x, dy = a.y - o.y
                    let ox = (a.width + o.width) / 2 + gap - abs(dx)
                    let oy = (a.height + o.height) / 2 + gap - abs(dy)
                    guard ox > 0, oy > 0 else { continue }
                    moved = true
                    if ox / max(o.width, 1) < oy / max(o.height, 1) {
                        boxes[i].x += (dx >= 0 ? 1 : -1) * ox
                    } else {
                        boxes[i].y += (dy >= 0 ? 1 : -1) * oy
                    }
                }
            }
            if !moved { break }
        }
    }

    /// The free spot nearest `target` for a box of `size`: on top of nothing
    /// in `avoiding`, with `gap` round it. For a capture you move or a new
    /// one, so nothing else has to.
    public static func freeSpot(near target: MapPoint, size: MapSize, avoiding: [MapBox], gap: Double, step: Double) -> MapPoint {
        for k in 0..<40_000 {
            let r = step * Double(k).squareRoot()
            let a = Double(k) * 2.39996
            let x = target.x + r * cos(a) * 1.25, y = target.y + r * sin(a)
            let clear = !avoiding.contains { abs(x - $0.x) < (size.width + $0.width) / 2 + gap && abs(y - $0.y) < (size.height + $0.height) / 2 + gap }
            if clear { return MapPoint(x: x, y: y) }
        }
        return target
    }

    /// Two stable values in 0..<1 from a string.
    static func seed(_ text: String) -> (Double, Double) {
        var a = FNV(), b = FNV()
        a.add(text); b.add(text + "#")
        return (Double(a.value % 10_000) / 10_000, Double(b.value % 10_000) / 10_000)
    }
}
