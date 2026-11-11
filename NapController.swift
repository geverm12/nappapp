import Foundation
// import WatchKit
import UserNotifications

@MainActor
final class NapController: NSObject, ObservableObject {
    enum Phase {
        case idle
        case calibrating
        case monitoring
        case asleep
        case ringing
    }

    @Published var phase: Phase = .idle
    @Published var currentHR: Double?
    @Published var baselineHR: Double?
    @Published var wakeDate: Date?
    @Published var message: String = ""
    @Published var ringReason: String = ""

    private let workout = WorkoutManager()
    private let motion = MotionSampler()
    private var detector = SleepDetector(config: NapConfig.load())
    private var config = NapConfig.load()

    private var loopTask: Task<Void, Never>?
    private var alarmTask: Task<Void, Never>?
    private var hapticTask: Task<Void, Never>?

    private var isStarting = false
    private var sensorsRunning = false
    private var hrSamples: [Double] = []
    private var startedAt = Date()
    private var log: [String] = []

    private enum Alarm {
        static let repeats = 6
        static let spacing: TimeInterval = 20
        static let failsafePrefix = "siesta.failsafe."
        static let wakePrefix = "siesta.wake."

        static var allIDs: [String] {
            (0..<repeats).flatMap { ["\(failsafePrefix)\($0)", "\(wakePrefix)\($0)"] }
        }
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start() async {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        config = NapConfig.load()
        detector = SleepDetector(config: config)
        hrSamples = []
        log = ["t_seg,fase,pulso_medio,pulso_reposo,movimiento,tranquilos,dormido"]
        message = ""

        do {
            try await workout.requestAuthorization()
        } catch {
            message = "Permiso de Salud denegado"
            return
        }
        let notificationsAllowed = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false

        workout.onHeartRate = { [weak self] bpm in
            Task { @MainActor in self?.handleHeartRate(bpm) }
        }
        workout.onError = { [weak self] text in
            Task { @MainActor in self?.message = text }
        }

        do {
            try workout.start()
        } catch {
            message = "No se pudo iniciar: \(error.localizedDescription)"
            return
        }
        motion.start()
        sensorsRunning = true

        if !notificationsAllowed {
            message = "Notificaciones desactivadas: la alarma solo sonará con la app abierta"
        }

        startedAt = Date()
        phase = .calibrating
        scheduleAlarm(prefix: Alarm.failsafePrefix,
                      after: TimeInterval(config.maxWaitMinutes * 60),
                      body: "No te he detectado dormido. Fin del tiempo máximo.")
        loopTask = Task { await scanLoop() }
    }

    func stop() {
        loopTask?.cancel()
        alarmTask?.cancel()
        hapticTask?.cancel()
        stopSensors()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Alarm.allIDs)
        center.removeAllDeliveredNotifications()
        saveLog()
        phase = .idle
        message = ""
        currentHR = nil
        baselineHR = nil
        wakeDate = nil
    }

    private func stopSensors() {
        guard sensorsRunning else { return }
        sensorsRunning = false
        workout.stop()
        motion.stop()
        currentHR = nil
    }

    func checkWake() {
        guard phase == .asleep, let wake = wakeDate, Date() >= wake else { return }
        ring(reason: "Has dormido \(config.napDurationMinutes) min")
    }

    private func handleHeartRate(_ bpm: Double) {
        if Int(bpm) != currentHR.map({ Int($0) }) {
            currentHR = bpm
        }
        hrSamples.append(bpm)
    }

    private func scanLoop() async {
        try? await Task.sleep(for: .seconds(NapConfig.calibrationSeconds))
        guard !Task.isCancelled else { return }

        let baseline = mean(hrSamples)
        detector.setBaseline(baseline)
        baselineHR = baseline
        if baseline == nil, message.isEmpty {
            message = "Sin lecturas de pulso: se detectará solo por movimiento"
        }
        hrSamples = []
        _ = motion.drainMean()
        phase = .monitoring

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.scanIntervalSeconds),
                                  tolerance: .seconds(5))
            guard !Task.isCancelled else { return }
            scan()
            if phase != .monitoring { return }
        }
    }

    private func scan() {
        let sample = ScanSample(avgHR: mean(hrSamples), motionMean: motion.drainMean())
        hrSamples = []

        let asleep = detector.evaluate(sample)
        baselineHR = detector.baselineHR
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        log.append("\(elapsed),monitor,\(sample.avgHR.map { String(format: "%.1f", $0) } ?? ""),"
                   + "\(detector.baselineHR.map { String(format: "%.1f", $0) } ?? ""),"
                   + "\(String(format: "%.4f", sample.motionMean)),\(detector.progress),\(asleep)")

        if asleep {
            fellAsleep()
        } else if Date().timeIntervalSince(startedAt) >= TimeInterval(config.maxWaitMinutes * 60) {
            ring(reason: "No te has dormido en \(config.maxWaitMinutes) min")
        }
    }

    private func fellAsleep() {
        let now = Date()
        let seconds = TimeInterval(config.napDurationMinutes * 60)
        wakeDate = now.addingTimeInterval(seconds)
        phase = .asleep

        stopSensors()

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: (0..<Alarm.repeats).map { "\(Alarm.failsafePrefix)\($0)" })
        scheduleAlarm(prefix: Alarm.wakePrefix, after: seconds,
                      body: "Has dormido \(config.napDurationMinutes) min.")

        alarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.ring(reason: "Has dormido \(self?.config.napDurationMinutes ?? 0) min")
        }
    }

    private func ring(reason: String) {
        guard phase != .ringing, phase != .idle else { return }
        loopTask?.cancel()
        alarmTask?.cancel()
        ringReason = reason
        phase = .ringing

        hapticTask = Task { [weak self] in
            let end = Date().addingTimeInterval(Self.maxRingSeconds)
            while !Task.isCancelled, Date() < end {
                try? await Task.sleep(for: .seconds(1.5))
            }
            if !Task.isCancelled { self?.stopSensors() }
        }
    }

    private static let maxRingSeconds: TimeInterval = 5 * 60

    private func scheduleAlarm(prefix: String, after seconds: TimeInterval, body: String) {
        let center = UNUserNotificationCenter.current()
        for i in 0..<Alarm.repeats {
            let content = UNMutableNotificationContent()
            content.title = "¡Despierta!"
            content.body = body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, seconds + Double(i) * Alarm.spacing), repeats: false)
            center.add(UNNotificationRequest(identifier: "\(prefix)\(i)",
                                           content: content, trigger: trigger))
        }
    }

    private func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func saveLog() {
        guard log.count > 1,
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let name = "siesta-\(Int(startedAt.timeIntervalSince1970)).csv"
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent(name),
                                               atomically: true, encoding: .utf8)
    }
}

extension NapController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
