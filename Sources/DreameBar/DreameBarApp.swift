import SwiftUI
import AppKit

@main
struct DreameBarApp: App {
    @StateObject private var store = VacuumStore()

    init() {
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.status.isCleaning ? DreameBarAppSymbols.vacuumFill : DreameBarAppSymbols.vacuum)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: VacuumStore

    var body: some View {
        VStack(spacing: 0) {
            switch store.phase {
            case .signedOut: SignInView()
            case .working:
                ProgressView("Connecting to Dreame…").frame(maxWidth: .infinity, minHeight: 200)
            case .ready: ControlView()
            }
            if let error = store.error {
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .center))
    }
}

// MARK: - Signed in

struct ControlView: View {
    @EnvironmentObject var store: VacuumStore
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private func startRename() {
        guard let device = store.device else { return }
        draftName = store.displayName(device)
        renaming = true
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename(_ device: DreameDevice) {
        store.rename(device, to: draftName)
        renaming = false
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            stats
            mapCard
            ModePicker(mode: $store.mode)
            controls
        }
        .onAppear { Task { await store.refreshStatus() } }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if renaming, let device = store.device {
                    HStack(spacing: 6) {
                        TextField(device.name, text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 16, weight: .semibold))
                            .focused($nameFocused)
                            .onSubmit { commitRename(device) }
                            .onExitCommand { renaming = false }
                        Button { commitRename(device) } label: { Image(systemName: "checkmark.circle.fill") }
                            .foregroundStyle(Theme.accent)
                        Button { renaming = false } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain).font(.system(size: 18))
                } else if store.devices.count > 1 {
                    Picker("", selection: Binding(get: { store.device }, set: { if let d = $0 { store.select(d) } })) {
                        ForEach(store.devices) { Text(store.displayName($0)).tag(Optional($0)) }
                    }
                    .labelsHidden().fixedSize()
                } else {
                    Text(store.device.map(store.displayName) ?? "Vacuum")
                        .font(.system(size: 22, weight: .bold))
                        .onTapGesture(count: 2) { startRename() }
                        .help("Double-click to rename")
                }
                HStack(spacing: 6) {
                    BatteryBadge(level: store.status.battery, charging: store.status.isCharging)
                    if let battery = store.status.battery { Text("\(battery)%") }
                    Text("|").foregroundStyle(Theme.secondary.opacity(0.6))
                    Text(store.status.stateText)
                    if store.isLive {
                        HStack(spacing: 3) {
                            Circle().fill(Theme.charge).frame(width: 6, height: 6)
                            Text("Live").font(.system(size: 11, weight: .medium))
                        }
                        .help("Receiving live updates from the robot")
                    }
                    if store.busy { ProgressView().controlSize(.mini) }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Rename Robot…") { startRename() }
                if let device = store.device, store.hasNickname(device) {
                    Button("Use Dreamehome Name (\(device.name))") { store.rename(device, to: "") }
                }
                Divider()
                Button("Reload Map") { Task { await store.loadRooms() } }
                Button("Refresh Status") { Task { await store.refreshStatus() } }
                Divider()
                Button("Sign Out") { store.signOut() }
                Button("Quit DreameBar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private var stats: some View {
        HStack(spacing: 0) {
            Stat(value: store.status.cleanedArea.map(String.init) ?? "–", unit: "m²", label: "Cleaning Area")
            Stat(value: store.status.cleaningMinutes.map(String.init) ?? "–", unit: "min", label: "Runtime")
            Stat(value: store.status.battery.map(String.init) ?? "–", unit: "%", label: "Battery")
        }
    }

    private var mapCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Theme.card.opacity(0.6))
            if let map = store.map {
                MapView(map: map, selected: store.selectedRooms, roomMode: store.mode == .room) { store.toggleRoom($0) }
                    .padding(12)
                    .padding(.bottom, store.mode == .room ? 22 : 0)  // room for the selection hint
            } else if store.loadingMap {
                ProgressView("Loading map…").controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "map").font(.system(size: 28)).foregroundStyle(Theme.secondary)
                    Text(store.roomsError ?? "No map yet").font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await store.loadRooms() } }.controlSize(.small)
                }
                .padding()
            }
        }
        .frame(height: 300)
        .overlay(alignment: .bottom) {
            if store.mode == .room && store.map != nil {
                Text(store.selectedRooms.isEmpty ? "Tap rooms to choose where to clean"
                     : "\(store.selectedRooms.count) room\(store.selectedRooms.count == 1 ? "" : "s") selected")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center) {
            SideButton(icon: "square.3.layers.3d", tint: Theme.accent, label: "Reload Map") {
                Task { await store.loadRooms() }
            }
            Spacer()
            PlayButton(cleaning: store.status.isCleaning, enabled: store.primaryActionEnabled) { store.primaryAction() }
            Spacer()
            SideButton(icon: "bolt.fill", tint: Theme.charge, label: dockLabel) { store.dock() }
                .disabled(store.busy || store.status.isCharging)
        }
        .padding(.horizontal, 6)
    }

    private var dockLabel: String {
        switch store.status.state {
        case 13: return "Charging Completed"
        case 6, 24: return "Charging"
        case 5: return "Returning"
        default: return "Dock"
        }
    }
}

struct Stat: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 30, weight: .medium, design: .rounded))
                Text(unit).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BatteryBadge: View {
    let level: Int?
    let charging: Bool

    var body: some View {
        let symbol: String = {
            guard let level else { return "battery.0percent" }
            if charging { return "battery.100percent.bolt" }
            switch level {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }()
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(charging ? Theme.charge : .secondary, .secondary)
    }
}

struct ModePicker: View {
    @Binding var mode: CleanMode
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CleanMode.allCases, id: \.self) { m in
                Text(m.rawValue)
                    .font(.system(size: 14, weight: mode == m ? .semibold : .regular))
                    .foregroundStyle(mode == m ? Color.primary : Theme.secondary)
                    .frame(width: 96, height: 32)
                    .background {
                        if mode == m {
                            Capsule().fill(Theme.segmentThumb)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { mode = m } }
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.segmentTrack))
    }
}

struct PlayButton: View {
    let cleaning: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
                Image(systemName: cleaning ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: cleaning ? 0 : 2)
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(cleaning ? "Pause" : "Start cleaning")
    }
}

struct SideButton: View {
    let icon: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(tint)
                Text(label).font(.system(size: 11)).foregroundStyle(.primary)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(width: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Map

struct MapView: View {
    let map: VacuumMap
    let selected: Set<Int>
    let roomMode: Bool
    let onTapRoom: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(map.width), geo.size.height / CGFloat(map.height))
            let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
            let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
            let dim = roomMode && !selected.isEmpty

            ZStack(alignment: .topLeading) {
                if let image = map.image(selected: selected, dimUnselected: dim, dark: colorScheme == .dark) {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.none)
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in
                            if let id = map.roomID(atCellX: Int(p.x / scale), y: Int(p.y / scale)) { onTapRoom(id) }
                        }
                        .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
                }
                // The cleaning path, drawn like the app's white trace.
                Path { path in
                    for stroke in map.pathStrokes {
                        path.move(to: CGPoint(x: origin.x + stroke[0].x * scale, y: origin.y + stroke[0].y * scale))
                        for p in stroke.dropFirst() {
                            path.addLine(to: CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale))
                        }
                    }
                }
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)

                let labels = Self.labelPositions(map.rooms, origin: origin, scale: scale)
                ForEach(map.rooms) { room in
                    RoomChip(name: room.name, selected: roomMode && selected.contains(room.id))
                        .onTapGesture { onTapRoom(room.id) }
                        .position(labels[room.id] ?? .zero)
                }
                if let charger = map.charger {
                    Circle().strokeBorder(Theme.charge, lineWidth: 2.5)
                        .background(Circle().fill(.white))
                        .frame(width: 14, height: 14)
                        .position(x: origin.x + charger.x * scale, y: origin.y + charger.y * scale)
                        .help("Dock")
                }
                if let robot = map.robot, robot != map.charger {
                    Circle().fill(.white)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 3))
                        .frame(width: 16, height: 16)
                        .shadow(radius: 2)
                        .position(x: origin.x + robot.x * scale, y: origin.y + robot.y * scale)
                        .animation(.linear(duration: 0.8), value: robot)
                        .help("Robot")
                }
            }
        }
    }

    /// Label centres, nudged vertically so chips don't overlap (the chip size is estimated from the text).
    static func labelPositions(_ rooms: [Room], origin: CGPoint, scale: CGFloat) -> [Int: CGPoint] {
        var placed: [(id: Int, rect: CGRect)] = []
        for room in rooms.sorted(by: { $0.center.y < $1.center.y }) {
            let size = CGSize(width: 26 + CGFloat(room.name.count) * 6.4, height: 22)
            var rect = CGRect(x: origin.x + room.center.x * scale - size.width / 2,
                              y: origin.y + room.center.y * scale - size.height / 2,
                              width: size.width, height: size.height)
            for other in placed where other.rect.intersects(rect) {
                rect.origin.y = other.rect.maxY + 2
            }
            placed.append((room.id, rect))
        }
        return Dictionary(uniqueKeysWithValues: placed.map { ($0.id, CGPoint(x: $0.rect.midX, y: $0.rect.midY)) })
    }
}

struct RoomChip: View {
    let name: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: selected ? "checkmark.circle.fill" : "house")
                .font(.system(size: 9, weight: .semibold))
            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Capsule().fill(selected ? Theme.accent : Theme.chip))
        .fixedSize()
    }
}

// MARK: - Signed out

struct SignInView: View {
    @EnvironmentObject var store: VacuumStore
    @State private var email = ""
    @State private var password = ""
    @State private var region = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: DreameBarAppSymbols.vacuum)
                    .font(.system(size: 22)).foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to Dreamehome").font(.system(size: 17, weight: .bold))
                    Text("Same account as the iPhone app").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                TextField("Email or phone", text: $email)
                    .textContentType(.username)
                    .textFieldStyle(.plain).padding(12)
                Divider().padding(.leading, 12)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.plain).padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            Picker("Server", selection: $region) {
                Text("Find automatically").tag("auto")
                ForEach(Dreame.regions, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            .font(.caption)
            Button {
                Task { await store.signIn(email: email, password: password, region: region == "auto" ? nil : region) }
            } label: {
                Text("Sign In").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)
            Text("Signed up with Apple or Google? Set a password in the Dreamehome app first. Only the login token is saved, in your keychain.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link).font(.caption)
            }
        }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// "robotic.vacuum" only exists in newer SF Symbols; fall back to a fan.
enum DreameBarAppSymbols {
    static let vacuum = available("robotic.vacuum") ?? "fan"
    static let vacuumFill = available("robotic.vacuum.fill") ?? "fan.fill"

    private static func available(_ name: String) -> String? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : nil
    }
}
