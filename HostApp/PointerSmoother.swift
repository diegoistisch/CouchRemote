import Foundation

/// Spielt eingehende Zeigerbewegungen gleichmäßig ab.
///
/// WLAN liefert Pakete nicht im festen Takt, sondern oft gebündelt (mehrere auf einmal, dann eine
/// Pause). Würde jede Bewegung sofort ausgeführt, macht der Zeiger kleine Sprünge. Stattdessen
/// landen Bewegungen in einem Puffer, der in einem festen 250-Hz-Takt exponentiell geleert wird:
/// pro Schritt der Anteil `1 - e^(-Schritt/τ)`. Mit τ = 8 ms ist eine Bewegung nach ~8 ms zu 63 %
/// und nach ~24 ms zu 95 % ausgeführt – kaum spürbare Verzögerung, aber ein gleichmäßiger Zeiger.
///
/// Läuft komplett auf der Netzwerk-Queue (`queue`), nie auf dem Main-Thread.
final class PointerSmoother: @unchecked Sendable {
    /// Zeitkonstante τ in Millisekunden (0 = aus), in den Einstellungen gespeichert.
    static let defaultsKey = "pointerSmoothingMs"
    static let defaultMilliseconds = 8.0
    static let options: [(milliseconds: Double, title: String)] = [
        (0, "Aus"), (5, "Leicht"), (8, "Mittel"), (14, "Stark")
    ]

    private static let step: TimeInterval = 0.004 // 250 Hz

    private let queue: DispatchQueue
    private let output: (Double, Double) -> Void
    private var pendingX = 0.0
    private var pendingY = 0.0
    private var timer: DispatchSourceTimer?
    private var idleSteps = 0

    init(queue: DispatchQueue, output: @escaping (Double, Double) -> Void) {
        self.queue = queue
        self.output = output
    }

    private var timeConstant: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Double ?? Self.defaultMilliseconds
        return max(stored, 0) / 1000
    }

    /// Nur auf `queue` aufrufen.
    func add(dx: Double, dy: Double) {
        guard timeConstant > 0 else {
            flush()
            output(dx, dy)
            return
        }
        pendingX += dx
        pendingY += dy
        idleSteps = 0
        startTimer()
    }

    /// Rest sofort ausführen, z. B. vor einem Klick, damit er an der richtigen Stelle landet.
    func flush() {
        guard pendingX != 0 || pendingY != 0 else { return }
        output(pendingX, pendingY)
        pendingX = 0
        pendingY = 0
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.step, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let tau = max(timeConstant, 0.001)
        let fraction = 1 - exp(-Self.step / tau)
        var emitX = pendingX * fraction
        var emitY = pendingY * fraction
        // Kleine Reste nicht ewig mitschleppen
        if abs(pendingX) < 0.4 && abs(pendingY) < 0.4 {
            emitX = pendingX
            emitY = pendingY
        }
        pendingX -= emitX
        pendingY -= emitY

        if emitX != 0 || emitY != 0 {
            output(emitX, emitY)
            idleSteps = 0
        } else {
            idleSteps += 1
            if idleSteps > 60 { // ~0,25 s nichts zu tun → Timer schlafen legen
                timer?.cancel()
                timer = nil
            }
        }
    }
}

/// Misst, wie gleichmäßig Trackpad-Pakete ankommen (Abstände zwischen Paketen während einer Bewegung).
struct PacketTiming {
    private var last: TimeInterval?
    private var gaps: [TimeInterval] = []

    mutating func record(at time: TimeInterval) {
        if let last, time - last < 0.3 { // längere Pausen = Finger war weg
            gaps.append(time - last)
        }
        last = time
    }

    /// Zusammenfassung der seit dem letzten Aufruf gesammelten Abstände; danach zurückgesetzt.
    mutating func takeSummary() -> String? {
        guard gaps.count >= 10 else { return nil }
        defer { gaps.removeAll(keepingCapacity: true) }
        let sorted = gaps.sorted()
        let average = gaps.reduce(0, +) / Double(gaps.count)
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let worst = sorted.last ?? 0
        let hiccups = gaps.filter { $0 > 0.05 }.count
        return String(format: "Ø %.0f ms · 95 %% unter %.0f ms · max %.0f ms · %d Aussetzer > 50 ms",
                      average * 1000, p95 * 1000, worst * 1000, hiccups)
    }
}
