import Foundation
import CoreGraphics

struct Room: Identifiable, Hashable {
    let id: Int
    var name: String
    /// True when the name came from the map (custom name or room type), not the "Room N" fallback.
    var named: Bool
    /// Label position in map grid cells (display orientation).
    let center: CGPoint
    let colorIndex: Int
}

/// Robot coordinates in millimetres, as reported in map headers and live map frames.
struct MapPoint: Equatable {
    let x: Int
    let y: Int
}

/// One point of the cleaning path; `move` starts a new stroke instead of drawing a line to it.
struct PathPoint: Equatable {
    let point: MapPoint
    let move: Bool
}

/// A live map frame from the robot: "I" frames carry the whole path, "P" frames only what's new.
struct MapFrame {
    let isFull: Bool
    let robot: MapPoint?
    let path: [PathPoint]
}

/// A decoded map in display orientation (flipped and rotated like the Dreamehome app), cropped to the floor.
struct VacuumMap {
    static let outside: UInt8 = 0
    static let wall: UInt8 = 254
    static let floor: UInt8 = 255

    let mapID: Int
    let width: Int
    let height: Int
    /// Row-major cells: 0 outside, 1...63 room id, `wall`, or `floor` (floor not assigned to a room).
    let cells: [UInt8]
    var rooms: [Room]
    var chargerMM: MapPoint?
    var robotMM: MapPoint?
    /// The current cleaning run's path, oldest first.
    var path: [PathPoint] = []
    /// A saved map embedded in this one ("rism"), which carries the cleaned-up rooms and their names.
    let embeddedSavedMap: String?

    // Grid transform from millimetres to display cells.
    let grid: Int
    let left: Int
    let top: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let rotation: Int
    let cropX: Int
    let cropY: Int

    func roomID(atCellX x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let v = Int(cells[y * width + x])
        return (1...63).contains(v) ? v : nil
    }

    var charger: CGPoint? { chargerMM.flatMap(cellPoint) }
    var robot: CGPoint? { robotMM.flatMap(cellPoint) }

    /// The path as strokes of display-cell points.
    var pathStrokes: [[CGPoint]] {
        var strokes: [[CGPoint]] = []
        for p in path {
            guard let c = cellPoint(p.point) else { continue }
            if p.move || strokes.isEmpty { strokes.append([c]) } else { strokes[strokes.count - 1].append(c) }
        }
        return strokes.filter { $0.count > 1 }
    }

    mutating func apply(_ frame: MapFrame) {
        if frame.isFull { path = frame.path } else { path += frame.path }
        if let robot = frame.robot { robotMM = robot }
    }

    func cellPoint(_ p: MapPoint) -> CGPoint? {
        let px = Double(p.x - left) / Double(grid)
        let py = Double(p.y - top) / Double(grid)
        guard px >= 0, py >= 0, px < Double(sourceWidth), py < Double(sourceHeight) else { return nil }
        let (dx, dy) = DreameMap.toDisplay(px, py, w: Double(sourceWidth), h: Double(sourceHeight), rotation: rotation)
        return CGPoint(x: dx - Double(cropX), y: dy - Double(cropY))
    }

    /// Copies names from another decode of the same home (for example the saved map) onto unnamed rooms.
    mutating func adoptNames(from other: VacuumMap) {
        let names = Dictionary(other.rooms.filter(\.named).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for i in rooms.indices where !rooms[i].named {
            if let name = names[rooms[i].id] {
                rooms[i].name = name
                rooms[i].named = true
            }
        }
        rooms.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var hasUnnamedRooms: Bool { rooms.contains { !$0.named } }
}

/// Decodes Dreame map files, following DreameVacuumMapDecoder in Tasshack/dreame-vacuum (map.py).
enum DreameMap {
    private static let headerSize = 27

    private static let roomTypeNames: [Int: String] = [
        1: "Living Room", 2: "Primary Bedroom", 3: "Study", 4: "Kitchen", 5: "Dining Hall",
        6: "Bathroom", 7: "Balcony", 8: "Corridor", 9: "Utility Room", 10: "Closet",
        11: "Meeting Room", 12: "Office", 13: "Fitness Area", 14: "Recreation Area", 15: "Secondary Bedroom",
    ]

    /// The renderer flips rows, then applies the map rotation ("mra") with PIL's counter-clockwise transpose.
    static func toDisplay(_ x: Double, _ y: Double, w: Double, h: Double, rotation: Int) -> (Double, Double) {
        let fy = h - y
        switch rotation {
        case 90: return (fy, w - x)
        case 180: return (w - x, h - fy)
        case 270: return (h - fy, x)
        default: return (x, fy)
        }
    }

    /// Inflates a map string: URL-safe base64, optionally AES-encrypted (",key" suffix), zlib-compressed.
    static func inflate(raw: String, key: String?, model: String) throws -> [UInt8] {
        // The Python decoder swaps URL-safe characters before splitting off the key, so the key gets them too.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        var key = key
        if key == nil, let comma = text.firstIndex(of: ",") {
            key = String(text[text.index(after: comma)...])
            text = String(text[..<comma])
        }
        guard var bytes = Crypto.base64Decode(text) else { throw DreameError("Map file isn't valid base64") }

        if let key {
            guard let iv = ModelKeys.iv(forModel: model) else {
                throw DreameError("No map key known for model \(model)")
            }
            let aesKey = Data(Crypto.sha256Hex(key).prefix(32).utf8)
            guard let plain = Crypto.aesCBCDecrypt(bytes, key: aesKey, iv: Data(iv.utf8)) else {
                throw DreameError("Map decryption failed")
            }
            bytes = plain
        }

        guard let inflated = Crypto.zlibInflate(bytes), inflated.count >= headerSize else {
            throw DreameError("Map decompression failed")
        }
        return [UInt8](inflated)
    }

    /// Reads the robot position and path from a live map frame (property 6.1).
    static func frame(raw: String, model: String) -> MapFrame? {
        guard let b = try? inflate(raw: raw, key: nil, model: model) else { return nil }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8)) }
        let x = i16(5), y = i16(7)
        let imageSize = headerSize + (Int(b[19]) | Int(b[20]) << 8) * (Int(b[21]) | Int(b[22]) << 8)
        let json = b.count > imageSize ? JSON.parse(Data(b[imageSize...])) : nil
        return MapFrame(isFull: b[4] == 73,  // "I"
                        robot: x == 0 && y == 0 ? nil : MapPoint(x: x, y: y),
                        path: parsePath(json?["tr"]?.string ?? ""))
    }

    /// The "tr" path string (map.py): M/W/S/l are absolute points, L is relative to the previous point.
    /// M, W and S start a new stroke; l continues the previous frame's stroke.
    static func parsePath(_ tr: String) -> [PathPoint] {
        var out: [PathPoint] = []
        var current = MapPoint(x: 0, y: 0)
        let scanner = Scanner(string: tr)
        scanner.charactersToBeSkipped = nil
        while !scanner.isAtEnd {
            guard let op = scanner.scanCharacter(), "MWSLl".contains(op),
                  let x = scanner.scanInt(), scanner.scanString(",") != nil, let y = scanner.scanInt() else { continue }
            if op == "L" {
                current = MapPoint(x: current.x + x, y: current.y + y)
                out.append(PathPoint(point: current, move: false))
            } else {
                current = MapPoint(x: x, y: y)
                out.append(PathPoint(point: current, move: op != "l"))
            }
        }
        return out
    }

    static func decode(raw: String, key: String?, model: String, rotation rotationOverride: Int? = nil) throws -> VacuumMap {
        let b = try inflate(raw: raw, key: key, model: model)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(o)))) }

        let grid = max(1, u16(17))
        let w = u16(19), h = u16(21)
        let left = i16(23), top = i16(25)
        let imageSize = headerSize + w * h
        guard w > 0, h > 0, b.count > imageSize, let json = JSON.parse(Data(b[imageSize...])) else {
            throw DreameError("Map has no room data")
        }
        let segInfo = json["seg_inf"]?.object ?? [:]
        let knownIDs = Set(segInfo.keys.compactMap(Int.init))

        // The pixel format differs between firmware generations; use whichever matches the room list best.
        let raw = Array(b[headerSize..<imageSize])
        let candidates = [("default", classifyDefault(raw)), ("v3", classifyV3(raw)), ("frame", classifyFrameMap(raw))]
        let (format, cellsData) = candidates.max { score($0.1, knownIDs) < score($1.1, knownIDs) }!

        let rotation = (rotationOverride ?? json["mra"]?.int ?? 0) % 360
        let (dw, dh) = rotation == 90 || rotation == 270 ? (h, w) : (w, h)
        func cell(_ x: Int, _ y: Int) -> (Int, Int) {
            // Same transform as toDisplay, on cell indices.
            let fy = h - 1 - y
            switch rotation {
            case 90: return (fy, w - 1 - x)
            case 180: return (w - 1 - x, h - 1 - fy)
            case 270: return (h - 1 - fy, x)
            default: return (x, fy)
            }
        }

        var display = [UInt8](repeating: VacuumMap.outside, count: dw * dh)
        var minX = dw, minY = dh, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let v = cellsData[y * w + x]
                guard v != VacuumMap.outside else { continue }
                let (dx, dy) = cell(x, y)
                display[dy * dw + dx] = v
                minX = min(minX, dx); maxX = max(maxX, dx)
                minY = min(minY, dy); maxY = max(maxY, dy)
            }
        }
        guard maxX >= 0 else { throw DreameError("The map is empty") }

        // Crop to the floor plus a small margin.
        let margin = 2
        let cx0 = max(0, minX - margin), cy0 = max(0, minY - margin)
        let cw = min(dw, maxX + margin + 1) - cx0, ch = min(dh, maxY + margin + 1) - cy0
        var cells = [UInt8](repeating: VacuumMap.outside, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw { cells[y * cw + x] = display[(y + cy0) * dw + (x + cx0)] }
        }

        func point(_ offset: Int) -> MapPoint? {
            let x = i16(offset), y = i16(offset + 2)
            return x == 0 && y == 0 ? nil : MapPoint(x: x, y: y)
        }

        let rooms = buildRooms(cells: cells, width: cw, height: ch, segInfo: segInfo)
        Log.write("map \(u16(0)): \(w)x\(h) rot \(rotation) format \(format), seg_inf \(segInfo.count), "
                  + "rooms \(rooms.count) (\(rooms.filter(\.named).count) named), keys \(json.object?.keys.sorted() ?? [])")
        return VacuumMap(mapID: u16(0), width: cw, height: ch, cells: cells, rooms: rooms,
                         chargerMM: point(11), robotMM: point(5), path: parsePath(json["tr"]?.string ?? ""),
                         embeddedSavedMap: json["rism"]?.string,
                         grid: grid, left: left, top: top, sourceWidth: w, sourceHeight: h,
                         rotation: rotation, cropX: cx0, cropY: cy0)
    }

    /// Saved maps listed in the map list file (property 6.8): (raw map, rotation, rismobj object name).
    static func savedMapEntries(listJSON: JSON) -> [(raw: String?, angle: Int, objectName: String?)] {
        (listJSON["mapstr"]?.array ?? []).map {
            ($0["map"]?.string, $0["angle"]?.int ?? 0, $0["rismobj"]?.string)
        }
    }

    // MARK: Pixel formats (map.py decode_map, frame type I)

    /// Most saved maps: low 6 bits room id, top bit marks a wall edge.
    private static func classifyDefault(_ raw: [UInt8]) -> [UInt8] {
        raw.map { p in
            guard p > 0 else { return VacuumMap.outside }
            let seg = p & 0x3F
            if p >> 7 != 0 { return seg == 0 ? VacuumMap.wall : seg }
            return seg > 0 ? seg : VacuumMap.outside
        }
    }

    /// Version 3 maps: low 5 bits room id (31 = unassigned floor), bits 5-6 wall flags.
    private static func classifyV3(_ raw: [UInt8]) -> [UInt8] {
        raw.map { p in
            let seg = p & 0x1F
            let wall = (p >> 5) & 0x03
            if seg == 0 { return VacuumMap.outside }
            if seg == 31 { return wall == 1 || wall == 2 ? VacuumMap.wall : VacuumMap.floor }
            return wall == 1 || wall == 2 ? VacuumMap.wall : seg
        }
    }

    /// "Frame map" models: room id in the top 6 bits.
    private static func classifyFrameMap(_ raw: [UInt8]) -> [UInt8] {
        raw.map { p in
            guard p > 0 else { return VacuumMap.outside }
            let seg = p >> 2
            switch seg {
            case 63: return VacuumMap.wall
            case 61, 62: return VacuumMap.floor
            case 1...60: return seg
            default:
                let low = p & 0x3F
                return low == 2 ? VacuumMap.wall : (low == 1 || low == 3 ? VacuumMap.floor : VacuumMap.outside)
            }
        }
    }

    private static func score(_ cells: [UInt8], _ known: Set<Int>) -> Int {
        var seen = Set<Int>(), inKnown = 0
        for v in cells where (1...63).contains(v) {
            seen.insert(Int(v))
            if known.contains(Int(v)) { inKnown += 1 }
        }
        // Reward formats whose rooms match seg_inf; without seg_inf, prefer the one with the most room pixels.
        return known.isEmpty ? inKnown + cells.filter { (1...63).contains($0) }.count : inKnown - (seen.subtracting(known).count * 50)
    }

    // MARK: Rooms

    private static func buildRooms(cells: [UInt8], width: Int, height: Int, segInfo: [String: JSON]) -> [Room] {
        var sums: [Int: (x: Double, y: Double, n: Double)] = [:]
        var bounds: [Int: (minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let v = Int(cells[y * width + x])
                guard (1...63).contains(v) else { continue }
                let s = sums[v] ?? (0, 0, 0)
                sums[v] = (s.x + Double(x), s.y + Double(y), s.n + 1)
                let b = bounds[v] ?? (x, y, x, y)
                bounds[v] = (min(b.minX, x), min(b.minY, y), max(b.maxX, x), max(b.maxY, y))
            }
        }
        // Rooms whose outlines come within a short distance count as neighbours for colouring;
        // saved maps leave gaps instead of walls between rooms, so touching pixels aren't enough.
        let reach = max(8, min(width, height) / 12)
        var neighbors: [Int: Set<Int>] = [:]
        for (a, ba) in bounds {
            for (b, bb) in bounds where a < b {
                let apart = ba.maxX + reach < bb.minX || bb.maxX + reach < ba.minX
                    || ba.maxY + reach < bb.minY || bb.maxY + reach < ba.minY
                if !apart {
                    neighbors[a, default: []].insert(b)
                    neighbors[b, default: []].insert(a)
                }
            }
        }
        for (k, v) in segInfo {
            guard let id = Int(k), let nei = v["nei_id"]?.array else { continue }
            for n in nei.compactMap(\.int) where n != id {
                neighbors[id, default: []].insert(n)
                neighbors[n, default: []].insert(id)
            }
        }

        // Greedy four-colouring, most-connected rooms first, like the app's alternating room colours.
        // If four colours run out, reuse the one least used among the room's neighbours.
        var colors: [Int: Int] = [:]
        let order = sums.keys.sorted {
            (neighbors[$0]?.count ?? 0, sums[$0]!.n) > (neighbors[$1]?.count ?? 0, sums[$1]!.n)
        }
        for id in order {
            let used = (neighbors[id] ?? []).compactMap { colors[$0] }
            colors[id] = (0..<4).first { !used.contains($0) }
                ?? (0..<4).min { a, b in used.filter { $0 == a }.count < used.filter { $0 == b }.count }!
        }

        return sums.map { id, s in
            // Put the label on the room cell closest to its centroid, so L-shaped rooms keep it inside.
            let c = CGPoint(x: s.x / s.n, y: s.y / s.n)
            var best = c, bestDist = Double.infinity
            for y in 0..<height {
                for x in 0..<width where Int(cells[y * width + x]) == id {
                    let d = (Double(x) - c.x) * (Double(x) - c.x) + (Double(y) - c.y) * (Double(y) - c.y)
                    if d < bestDist { bestDist = d; best = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5) }
                }
            }
            let label = name(info: segInfo[String(id)])
            return Room(id: id, name: label ?? "Room \(id)", named: label != nil, center: best, colorIndex: colors[id] ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func name(info: JSON?) -> String? {
        guard let info else { return nil }
        if let encoded = info["name"]?.string, !encoded.isEmpty,
           let data = Data(base64Encoded: encoded), let custom = String(data: data, encoding: .utf8), !custom.isEmpty {
            return custom
        }
        if let type = info["type"]?.int, let typeName = roomTypeNames[type] {
            let index = info["index"]?.int ?? 0
            return index > 0 ? "\(typeName) \(index + 1)" : typeName
        }
        return nil
    }
}
