import SwiftUI
import UIKit

/// Trackpad-Fläche auf Basis von UIKit-Touches (näher an der Hardware als eine SwiftUI-Geste).
///
/// - 1 Finger bewegen → Zeiger (mit allen koaleszierten Zwischenpunkten)
/// - 1 Finger tippen → Klick
/// - 2 Finger bewegen → Scrollen
/// - 2 Finger tippen → Rechtsklick
struct TrackpadSurface: UIViewRepresentable {
    /// dx, dy in Punkten und die Zeit seit dem letzten Event in Sekunden.
    var onMove: (_ dx: Double, _ dy: Double, _ dt: Double) -> Void
    var onScroll: (_ dx: Double, _ dy: Double) -> Void
    var onTap: () -> Void
    var onTwoFingerTap: () -> Void

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TrackpadUIView, context: Context) {
        view.onMove = onMove
        view.onScroll = onScroll
        view.onTap = onTap
        view.onTwoFingerTap = onTwoFingerTap
    }
}

final class TrackpadUIView: UIView {
    var onMove: (Double, Double, Double) -> Void = { _, _, _ in }
    var onScroll: (Double, Double) -> Void = { _, _ in }
    var onTap: () -> Void = {}
    var onTwoFingerTap: () -> Void = {}

    private var activeTouches = Set<UITouch>()
    private var maxTouches = 0
    private var gestureStart: TimeInterval = 0
    private var travelled: Double = 0
    private var lastMoveTimestamp: TimeInterval?

    /// Bis zu dieser Strecke/Dauer gilt eine Berührung als Tippen.
    private static let tapMaxTravel: Double = 10
    private static let tapMaxDuration: TimeInterval = 0.3

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.isEmpty {
            maxTouches = 0
            travelled = 0
            gestureStart = event?.timestamp ?? 0
            lastMoveTimestamp = nil
        }
        activeTouches.formUnion(touches)
        maxTouches = max(maxTouches, activeTouches.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.count == 1, let touch = touches.first {
            // Alle Zwischenpunkte seit dem letzten Event (Touch-Abtastung ist schneller als die Bildrate).
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            var dx = 0.0, dy = 0.0
            for sample in samples {
                let now = sample.location(in: self)
                let before = sample.previousLocation(in: self)
                dx += now.x - before.x
                dy += now.y - before.y
            }
            let timestamp = samples.last?.timestamp ?? touch.timestamp
            let dt = lastMoveTimestamp.map { max(timestamp - $0, 0.001) } ?? (1.0 / 120)
            lastMoveTimestamp = timestamp

            travelled += (dx * dx + dy * dy).squareRoot()
            guard dx != 0 || dy != 0 else { return }
            onMove(dx, dy, dt)
        } else if activeTouches.count >= 2 {
            // Durchschnittliche Bewegung der Finger = Scrollen.
            let moved = touches.filter { activeTouches.contains($0) }
            guard !moved.isEmpty else { return }
            var dx = 0.0, dy = 0.0
            for touch in moved {
                let now = touch.location(in: self)
                let before = touch.previousLocation(in: self)
                dx += now.x - before.x
                dy += now.y - before.y
            }
            dx /= Double(moved.count)
            dy /= Double(moved.count)
            travelled += (dx * dx + dy * dy).squareRoot()
            onScroll(dx, dy)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        guard activeTouches.isEmpty else { return }
        lastMoveTimestamp = nil

        let duration = (event?.timestamp ?? gestureStart) - gestureStart
        guard travelled < Self.tapMaxTravel, duration < Self.tapMaxDuration else { return }
        if maxTouches >= 2 {
            onTwoFingerTap()
        } else {
            onTap()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        if activeTouches.isEmpty { lastMoveTimestamp = nil }
    }
}
