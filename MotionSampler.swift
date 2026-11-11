import CoreMotion

/// Mide el movimiento de la muñeca (aceleración del usuario, sin gravedad).
///
/// `nonisolated`: los proyectos nuevos de Xcode aíslan todo al hilo principal por
/// defecto, y el handler de CoreMotion corre en otra cola; sin esto la app se cerraría
/// por la comprobación de aislamiento de Swift. El acceso compartido va protegido por `lock`.
nonisolated final class MotionSampler: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var sum = 0.0
    private var count = 0

    init() {
        queue.maxConcurrentOperationCount = 1
    }

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        // 2 Hz basta para distinguir "quieto" de "moviéndose" y gasta mucho menos que 5-10 Hz.
        manager.deviceMotionUpdateInterval = 0.5
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let a = motion?.userAcceleration else { return }
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.lock.lock()
            self.sum += magnitude
            self.count += 1
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Devuelve el movimiento medio desde la última llamada y reinicia el acumulador.
    func drainMean() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let mean = count > 0 ? sum / Double(count) : 0
        sum = 0
        count = 0
        return mean
    }
}
