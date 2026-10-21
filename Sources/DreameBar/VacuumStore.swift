import Foundation
import SwiftUI

struct VacuumStatus {
    var state: Int?
    var battery: Int?
    var suction: Int?
    var water: Int?
    var cleaningMinutes: Int?
    var cleanedArea: Int?
    var customizedCleaning = false

    // DreameVacuumState values from Tasshack/dreame-vacuum types.py
    var stateText: String {
        switch state {
        case 1: return "Sweeping"
        case 2: return "Idle"
        case 3: return "Paused"
        case 4: return "Error"
        case 5: return "Returning to dock"
        case 6: return "Charging"
        case 7: return "Mopping"
        case 8: return "Drying mop"
        case 9: return "Washing mop"
        case 10: return "Returning to wash"
        case 11: return "Mapping"
        case 12: return "Sweeping and mopping"
        case 13: return "Fully charged"
        case 14: return "Updating firmware"
        case 22, 34: return "Emptying dust bin"
        case 24: return "Smart charging"
        case 27: return "Spot cleaning"
        case nil: return "Unknown"
        default: return "Busy (\(state!))"
        }
    }

    var isCleaning: Bool { [1, 7, 11, 12, 25, 27, 38].contains(state ?? -1) }
    var isPaused: Bool { state == 3 }
    var isCharging: Bool { [6, 13, 24].contains(state ?? -1) }
}

enum CleanMode: String, CaseIterable {
    case room = "Room"
    case all = "All"
    case zone = "Zone"
}

@MainActor
final class VacuumStore: ObservableObject {
    enum Phase { case signedOut, working, ready }

    @Published var phase: Phase = .signedOut
    @Published var devices: [DreameDevice] = []
    @Published var device: DreameDevice?
    @Published var status = VacuumStatus()
    @Published var map: VacuumMap?
    @Published var mode: CleanMode = .all
    @Published var selectedRooms: Set<Int> = []
    /// Shapes drawn in Zone mode, in robot millimetres so they survive map reloads.
    @Published var areas: [CleanArea] = []
    /// Rectangles sent for all drawn shapes together; more than this and the robot may refuse the task.
    static let maxRects = 10
    @Published var roomsError: String?
    @Published var loadingMap = false

    /// Names set in DreameBar, keyed by device id. Dreame's cloud has no documented rename call,
    /// so these stay on this Mac and don't change the name in the iPhone app.
    @Published private(set) var nicknames: [String: String] =
        UserDefaults.standard.dictionary(forKey: "nicknames") as? [String: String] ?? [:]

    var rooms: [Room] { map?.rooms ?? [] }

    func displayName(_ d: DreameDevice) -> String { nicknames[d.did] ?? d.name }

    func hasNickname(_ d: DreameDevice) -> Bool { nicknames[d.did] != nil }

    /// An empty or unchanged name goes back to the name from the Dreamehome app.
    func rename(_ d: DreameDevice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[d.did] = trimmed.isEmpty || trimmed == d.name ? nil : trimmed
        UserDefaults.standard.set(nicknames, forKey: "nicknames")
    }
    @Published var error: String?
    @Published var busy = false

    /// True while the live feed is connected and pushing updates.
    @Published var isLive = false

    private var cloud: DreameCloud
    private var pollTask: Task<Void, Never>?
    private var isDemo = false
    private let live = DreameLive()
    private var liveRetry: Task<Void, Never>?
    private var mapReload: Task<Void, Never>?

    /// Offline store with sample data, used by the snapshot mode.
    init(demoMap: VacuumMap?, phase: Phase) {
        cloud = DreameCloud(session: nil)
        isDemo = true
        self.phase = phase
        let demo = DreameDevice(did: "0", model: "dreame.vacuum.demo", name: "Robot Vacuum", mac: "", bindDomain: "")
        devices = [demo]
        device = demo
        map = demoMap
        status = VacuumStatus(state: 6, battery: 99, suction: 1, water: 2, cleaningMinutes: 36, cleanedArea: 21)
    }

    init() {
        let saved = Keychain.load()
        cloud = DreameCloud(session: saved)
        if saved != nil {
            phase = .working
            Task { await connect() }
        }
    }

    // MARK: Session

    func signIn(email: String, password: String, region: String?) async {
        phase = .working
        error = nil
        var lastError: Error?
        for r in region.map({ [$0] }) ?? Dreame.regions {
            let candidate = DreameCloud(session: nil)
            do {
                let session = try await candidate.login(username: email, password: password, region: r)
                let vacuums = try await candidate.devices().filter { $0.model.contains(".vacuum.") }
                if vacuums.isEmpty && region == nil { continue }
                Keychain.save(session)
                cloud = candidate
                await connect()
                return
            } catch {
                lastError = error
                // A wrong password means the account exists in this region; trying others won't help.
                if error.localizedDescription.localizedCaseInsensitiveContains("password") { break }
            }
        }
        error = lastError?.localizedDescription ?? "No Dreame vacuum found on this account in any region."
        phase = .signedOut
    }

    func signOut() {
        pollTask?.cancel()
        stopLive()
        Keychain.clear()
        cloud = DreameCloud(session: nil)
        devices = []; device = nil; map = nil; selectedRooms = []; areas = []
        status = VacuumStatus()
        phase = .signedOut
    }

    private func connect() async {
        do {
            devices = try await cloud.devices().filter { $0.model.contains(".vacuum.") }
            Log.write("signed in, vacuums: " + devices.map { "\($0.model) via \($0.bindDomain)" }.joined(separator: ", "))
            if let s = await cloud.session { Keychain.save(s) }
            guard let first = devices.first else {
                error = "No vacuum on this Dreamehome account."
                phase = .signedOut
                return
            }
            device = devices.first(where: { $0.did == UserDefaults.standard.string(forKey: "deviceId") }) ?? first
            phase = .ready
            await refreshStatus()
            await loadRooms()
            startPolling()
            startLive()
        } catch {
            Log.write("connect failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
            phase = .signedOut
        }
    }

    func select(_ d: DreameDevice) {
        device = d
        UserDefaults.standard.set(d.did, forKey: "deviceId")
        map = nil; selectedRooms = []; areas = []
        Task { await refreshStatus(); await loadRooms(); startLive() }
    }

    /// Polls status as a backstop: rarely while the live feed works, every 5 s while cleaning without it.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let live = self?.isLive ?? false
                let cleaning = self?.status.isCleaning ?? false
                try? await Task.sleep(for: .seconds(live ? 60 : cleaning ? 5 : 20))
                await self?.refreshStatus()
            }
        }
    }

    // MARK: Live feed

    private func startLive() {
        guard let device, !isDemo else { return }
        liveRetry?.cancel()
        live.onConnectionChange = { [weak self] connected in
            self?.isLive = connected
            Log.write("live: \(connected ? "connected" : "not connected")")
        }
        live.onClosed = { [weak self] in self?.scheduleLiveRetry() }
        live.onMessage = { [weak self] data in self?.handleLive(data) }
        Task {
            do {
                live.connect(try await cloud.liveConfig(device))
            } catch {
                Log.write("live: \(error.localizedDescription)")
                scheduleLiveRetry()
            }
        }
    }

    private func stopLive() {
        liveRetry?.cancel()
        live.onClosed = nil
        live.disconnect()
        isLive = false
    }

    private func scheduleLiveRetry() {
        guard phase == .ready else { return }
        liveRetry?.cancel()
        liveRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.startLive()
        }
    }

    /// Handles a pushed message: {"method": "properties_changed", "params": [{siid, piid, value}, ...]}.
    private func handleLive(_ data: JSON) {
        guard data["method"]?.string == "properties_changed", let params = data["params"]?.array,
              let device else { return }
        for p in params {
            guard let siid = p["siid"]?.int, let piid = p["piid"]?.int, let value = p["value"] else { continue }
            switch (siid, piid) {
            case (2, 1): status.state = value.int
            case (3, 1): status.battery = value.int
            case (4, 2): status.cleaningMinutes = value.int
            case (4, 3): status.cleanedArea = value.int
            case (4, 4): status.suction = value.int
            case (4, 5): status.water = value.int
            case (6, 1):
                // A map frame: the robot's position and the newest piece of its path.
                if let raw = value.string, let frame = DreameMap.frame(raw: raw, model: device.model) {
                    map?.apply(frame)
                }
            case (6, 3):
                // The robot uploaded a new map (rooms edited, or a run finished); fetch it shortly.
                mapReload?.cancel()
                mapReload = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await self?.loadRooms()
                }
            default: break
            }
        }
    }

    // MARK: Status and rooms

    func refreshStatus() async {
        guard let device, !isDemo else { return }
        do {
            let p = try await cloud.properties(device, [(2, 1), (3, 1), (4, 2), (4, 3), (4, 4), (4, 5), (4, 26)])
            status.state = p["2.1"]?.int
            status.battery = p["3.1"]?.int
            status.cleaningMinutes = p["4.2"]?.int
            status.cleanedArea = p["4.3"]?.int
            status.suction = p["4.4"]?.int
            status.water = p["4.5"]?.int
            status.customizedCleaning = p["4.26"] != nil
            error = nil
            if let s = await cloud.session { Keychain.save(s) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadRooms() async {
        guard let device, !isDemo else { return }
        roomsError = nil
        loadingMap = true
        defer { loadingMap = false }
        do {
            guard let objectName = try await cloud.mapObjectName(device), !objectName.isEmpty else {
                roomsError = "The robot hasn't uploaded a map yet."
                return
            }
            let parts = objectName.split(separator: ",", maxSplits: 1).map(String.init)
            let raw = try await downloadText(device, parts[0])
            let live = try DreameMap.decode(raw: raw, key: parts.count > 1 ? parts[1] : nil, model: device.model)
            var shown = live

            // The live map often lacks room names; the saved map embedded in it ("rism") has them.
            if let embedded = live.embeddedSavedMap,
               let saved = try? DreameMap.decode(raw: embedded, key: nil, model: device.model, rotation: live.rotation),
               !saved.rooms.isEmpty {
                shown = saved
                shown.adoptNames(from: live)
                Log.write("using embedded saved map \(saved.mapID)")
            }
            if shown.hasUnnamedRooms, let saved = await savedMapMatching(shown, device: device) {
                shown.adoptNames(from: saved)
            }
            // Robot and dock positions come from the live frame; they're in millimetres, so they fit either map.
            shown.robotMM = live.robotMM ?? shown.robotMM
            shown.chargerMM = live.chargerMM ?? shown.chargerMM
            shown.path = live.path

            map = shown
            selectedRooms.formIntersection(rooms.map(\.id))
            Log.write("rooms: " + rooms.map { "\($0.id)=\($0.named ? "named" : "unnamed")" }.joined(separator: " "))
            if rooms.isEmpty { roomsError = "No rooms on the map. Split it into rooms in the Dreamehome app." }
        } catch {
            Log.write("map load failed: \(error.localizedDescription)")
            roomsError = "Couldn't load rooms: \(error.localizedDescription)"
        }
    }

    private func downloadText(_ device: DreameDevice, _ objectName: String) async throws -> String {
        let data = try await cloud.downloadFile(device, objectName: objectName)
        guard let text = String(data: data, encoding: .utf8) else { throw DreameError("Map file isn't text") }
        return text
    }

    /// Looks through the saved maps (map list, property 6.8) for the one whose rooms best match `map`.
    private func savedMapMatching(_ map: VacuumMap, device: DreameDevice) async -> VacuumMap? {
        do {
            guard let listName = try await cloud.mapListObjectName(device) else {
                Log.write("no map list object")
                return nil
            }
            guard let list = JSON.parse(Data(try await downloadText(device, listName).utf8)) else {
                Log.write("map list isn't JSON")
                return nil
            }
            let ids = Set(map.rooms.map(\.id))
            var best: (map: VacuumMap, overlap: Int)?
            for entry in DreameMap.savedMapEntries(listJSON: list) {
                var raw = entry.raw
                if raw == nil, let obj = entry.objectName { raw = try? await downloadText(device, obj) }
                guard let raw, let saved = try? DreameMap.decode(raw: raw, key: nil, model: device.model, rotation: entry.angle)
                else { continue }
                let overlap = Set(saved.rooms.filter(\.named).map(\.id)).intersection(ids).count
                if overlap > (best?.overlap ?? 0) { best = (saved, overlap) }
            }
            Log.write("map list: \(DreameMap.savedMapEntries(listJSON: list).count) saved maps, best overlap \(best?.overlap ?? 0)")
            return best?.map
        } catch {
            Log.write("map list failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Commands (siid/aiid from DreameVacuumActionMapping)

    /// The big play button: pause while cleaning, resume when paused, otherwise start the chosen mode.
    func primaryAction() {
        if status.isCleaning { pause() }
        else if status.isPaused || mode == .all { cleanWholeHouse() }
        else if mode == .zone { cleanZones() }
        else { cleanSelectedRooms() }
    }

    var primaryActionEnabled: Bool {
        guard !busy else { return false }
        if status.isCleaning || status.isPaused { return true }
        switch mode {
        case .all: return true
        case .room: return !selectedRooms.isEmpty
        case .zone: return !areas.isEmpty
        }
    }

    // MARK: Zones

    /// Adds a freehand shape traced through display-cell points. Returns a message when it can't be added.
    @discardableResult
    func addArea(_ points: [CGPoint]) -> String? {
        guard let map, points.count >= 3 else { return nil }
        let used = areas.reduce(0) { $0 + $1.rects.count }
        guard used < Self.maxRects else { return "That's as much as the robot takes. Remove a shape first." }
        let outline = points.map(map.mapPoint)
        guard let rects = CleanArea.cover(outline, grid: map.grid, maxRects: Self.maxRects - used) else {
            return used == 0 ? "That shape is too small to clean." : "Not enough room left for that shape. Remove one first."
        }
        areas.append(CleanArea(outline: outline, rects: rects))
        return nil
    }

    func removeArea(_ id: CleanArea.ID) { areas.removeAll { $0.id == id } }

    func cleanZones() {
        let rects = areas.flatMap(\.rects)
        guard !rects.isEmpty else { return }
        let fan = status.suction ?? 1
        let water = status.water ?? 2
        // Each area: [x0, y0, x1, y1, passes, suction, water] in millimetres.
        let list = rects.map { z in JSON.array(z.bounds.map { .int($0) } + [1, .int(fan), .int(water)]) }
        let payload = (["areas": .array(list)] as JSON).dumps()
        run {
            try await $0.action($1, siid: 4, aiid: 1, in: [
                ["piid": 1, "value": 19],  // status: zone cleaning
                ["piid": 10, "value": .string(payload)],
            ])
        }
    }

    func toggleRoom(_ id: Int) {
        mode = .room
        if selectedRooms.contains(id) { selectedRooms.remove(id) } else { selectedRooms.insert(id) }
    }

    func cleanWholeHouse() { run { try await $0.action($1, siid: 2, aiid: 1) } }
    func pause() { run { try await $0.action($1, siid: 2, aiid: 2) } }
    func resume() { cleanWholeHouse() }
    func stop() { run { try await $0.action($1, siid: 4, aiid: 2) } }
    func dock() { run { try await $0.action($1, siid: 3, aiid: 1) } }

    func cleanSelectedRooms() {
        let ids = rooms.map(\.id).filter(selectedRooms.contains)
        guard !ids.isEmpty else { return }
        let fan = status.suction ?? 1
        let water = status.water ?? 2
        let customized = status.customizedCleaning
        // Each entry: [room id, passes, suction, water, order]. Newer models expect order 1 for every room.
        let selects = ids.enumerated().map { i, id in
            JSON.array([.int(id), 1, .int(fan), .int(water), .int(customized ? 1 : i + 1)])
        }
        let payload = (["selects": .array(selects)] as JSON).dumps()
        run {
            try await $0.action($1, siid: 4, aiid: 1, in: [
                ["piid": 1, "value": 18],  // status: segment cleaning
                ["piid": 10, "value": .string(payload)],
            ])
        }
    }

    private func run(_ command: @escaping (DreameCloud, DreameDevice) async throws -> Void) {
        guard let device else { return }
        busy = true
        error = nil
        Task {
            do {
                try await command(cloud, device)
                try? await Task.sleep(for: .seconds(2))
                await refreshStatus()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
