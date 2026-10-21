import SwiftUI
import AppKit

/// Renders the popover to PNGs without signing in, for checking the design:
///   DREAMEBAR_SNAPSHOT_DIR=/path DREAMEBAR_DEMO_MAP=/path/map.txt DreameBar
enum Snapshot {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DREAMEBAR_SNAPSHOT_DIR"] else { return }
        if env["DREAMEBAR_SNAPSHOT_LIVE"] != nil {
            // Render the signed-in account's real map once it has loaded.
            Task { @MainActor in
                let store = VacuumStore()
                for _ in 0..<60 where store.map == nil || store.loadingMap {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    render(ContentView().environmentObject(store), appearance: appearance, scheme: scheme,
                           to: "\(dir)/live-\(scheme).png")
                }
                // Zone mode with two freehand sample shapes, traced the same way a drag would add them.
                if let map = store.map {
                    store.mode = .zone
                    let w = CGFloat(map.width), h = CGFloat(map.height)
                    func trace(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, wobble: CGFloat) -> [CGPoint] {
                        (0..<72).map { i in
                            let a = CGFloat(i) / 72 * 2 * .pi, r = 1 + wobble * sin(3 * a)
                            return CGPoint(x: w * (cx + rx * r * cos(a)), y: h * (cy + ry * r * sin(a)))
                        }
                    }
                    for message in [store.addArea(trace(cx: 0.33, cy: 0.62, rx: 0.13, ry: 0.09, wobble: 0)),
                                    store.addArea(trace(cx: 0.72, cy: 0.3, rx: 0.12, ry: 0.1, wobble: 0.25))] {
                        if let message { print("sample shape:", message) }
                    }
                    print("sample shapes use", store.areas.map(\.rects.count), "rectangles")
                    render(ContentView().environmentObject(store), appearance: .darkAqua, scheme: "dark",
                           to: "\(dir)/live-zone-dark.png")
                }
                exit(0)
            }
            return
        }
        MainActor.assumeIsolated {
            var map: VacuumMap?
            if let path = env["DREAMEBAR_DEMO_MAP"], let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                do { map = try DreameMap.decode(raw: raw, key: nil, model: "dreame.vacuum.demo") }
                catch { print("demo map failed:", error.localizedDescription) }
            }
            let ready = VacuumStore(demoMap: map, phase: .ready)
            let roomMode = VacuumStore(demoMap: map, phase: .ready)
            roomMode.mode = .room
            roomMode.selectedRooms = Set(map?.rooms.prefix(2).map(\.id) ?? [])
            let signIn = VacuumStore(demoMap: nil, phase: .signedOut)

            for (name, store) in [("all", ready), ("rooms", roomMode), ("signin", signIn)] {
                for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    render(ContentView().environmentObject(store), appearance: appearance, scheme: scheme,
                           to: "\(dir)/\(name)-\(scheme).png")
                }
            }
        }
        exit(0)
    }

    @MainActor
    private static func render(_ view: some View, appearance: NSAppearance.Name, scheme: String, to path: String) {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme == "dark" ? .dark : .light))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
