import Foundation
import WatchKit
import UserNotifications

/// Orquesta toda la siesta: calibración -> escaneo -> sueño detectado -> alarma.
///
/// Ahorro de batería: en cuanto se detecta el sueño se apagan el sensor de pulso,
/// la sesión de entrenamiento y el acelerómetro. La alarma queda en manos del sistema
/// (notificaciones locales repetidas), así que el reloj puede suspender la app.
@MainActor
final class NapController: NSObject, ObservableObject {
    enum Phase {
        case idle         // configurando
        case calibrating  // midiendo el pulso inicial
        case monitoring   // escaneando si te has dormido
        case asleep       // dormido: cuenta atrás hasta la alarma
        case ringing      // alarma sonando
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

    /// La alarma se programa varias veces seguidas para que un solo aviso perdido no impida despertar.
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

    // MARK: - Ciclo de vida

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
            // Sin notificaciones, con la app suspendida no sonaría nada al despertar.
            message = "Notificaciones desactivadas: la alarma solo sonará con la app abierta"
        }

        startedAt = Date()
        phase = .calibrating
        scheduleAlarm(prefix: Alarm.failsafePrefix,
                      after: TimeInterval(config.maxWaitMinutes * 60),
                      body: "No te he detectado dormido. Fin del tiempo máximo.")
        loopTask = Task { await scanLoop() }
    }

    /// Detiene todo y vuelve a la pantalla de ajustes.
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

    /// Apaga pulso, sesión de entrenamiento y acelerómetro (lo que más batería gasta).
    private func stopSensors() {
        guard sensorsRunning else { return }
        sensorsRunning = false
        workout.stop()
        motion.stop()
        currentHR = nil
    }

    /// Llamar al volver la app a primer plano: si la hora de despertar ya pasó
    /// mientras estaba suspendida, activa la alarma en pantalla.
    func checkWake() {
        guard phase == .asleep, let wake = wakeDate, Date() >= wake else { return }
        ring(reason: "Has dormido \(config.napDurationMinutes) min")
    }

    // MARK: - Escaneo

    private func handleHeartRate(_ bpm: Double) {
        // Solo se publica si cambia el valor mostrado: evita redibujar la pantalla sin necesidad.
        if Int(bpm) != currentHR.map({ Int($0) }) {
            currentHR = bpm
        }
        hrSamples.append(bpm)
    }

    private func scanLoop() async {
        // 1) Calibración: pulso de reposo despierto.
        try? await Task.sleep(for: .seconds(NapConfig.calibrationSeconds))
        guard !Task.isCancelled else { return }

        let baseline = mean(hrSamples)
        detector.setBaseline(baseline)
        baselineHR = baseline
        if baseline == nil, message.isEmpty {
            // HealthKit no avisa si deniegas el permiso de pulso: simplemente no llegan datos.
            message = "Sin lecturas de pulso: se detectará solo por movimiento"
        }
        hrSamples = []
        _ = motion.drainMean()
        phase = .monitoring

        // 2) Escaneos periódicos (con tolerancia para que el sistema agrupe despertares de CPU).
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
        baselineHR = detector.baselineHR  // pulso de reposo actualizado
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

    // MARK: - Dormido y alarma

    private func fellAsleep() {
        let now = Date()
        let seconds = TimeInterval(config.napDurationMinutes * 60)
        wakeDate = now.addingTimeInterval(seconds)
        phase = .asleep

        // Ya no hace falta medir nada: se apagan los sensores y manda la alarma del sistema.
        stopSensors()

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: (0..<Alarm.repeats).map { "\(Alarm.failsafePrefix)\($0)" })
        scheduleAlarm(prefix: Alarm.wakePrefix, after: seconds,
                      body: "Has dormido \(config.napDurationMinutes) min.")

        // Si la app sigue en primer plano, también suena/vibra dentro de la app.
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

        // Si salta por "Espera máx." la sesión de entrenamiento sigue viva: se mantiene
        // mientras vibra para que el háptico funcione aunque la muñeca esté bajada
        // (puede que te hayas dormido sin que se detectara). Tras la siesta ya está apagada.
        hapticTask = Task { [weak self] in
            let end = Date().addingTimeInterval(Self.maxRingSeconds)
            while !Task.isCancelled, Date() < end {
                WKInterfaceDevice.current().play(.notification)
                try? await Task.sleep(for: .seconds(1.5))
            }
            // Nadie la ha parado: se apagan sensores para no vaciar la batería.
            if !Task.isCancelled { self?.stopSensors() }
        }
    }

    /// Tiempo máximo vibrando dentro de la app si nadie pulsa "Parar".
    private static let maxRingSeconds: TimeInterval = 5 * 60

    // MARK: - Utilidades

    /// Programa `Alarm.repeats` notificaciones locales, una cada `Alarm.spacing` segundos.
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

    /// Guarda un CSV en Documentos para ajustar los umbrales después.
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
