import HealthKit

/// Mantiene la app viva en segundo plano (sesión de "entrenamiento") y
/// entrega el pulso cardíaco en directo. La sesión se descarta al terminar:
/// no se guarda nada en Salud ni en los anillos de Actividad.
///
/// `nonisolated`: HealthKit llama a los delegados desde colas propias, no desde el hilo principal.
/// `@unchecked Sendable`: los cierres de `DispatchQueue.main.async` capturan `self`; así compila
/// también con el modo de lenguaje Swift 6 de Xcode 27 (el estado solo se toca desde esos hilos de forma secuencial).
nonisolated final class WorkoutManager: NSObject, @unchecked Sendable {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// Se llama en el hilo principal con cada lectura de pulso (lpm).
    var onHeartRate: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    func requestAuthorization() async throws {
        let heartRate = HKQuantityType(.heartRate)
        try await store.requestAuthorization(
            toShare: [HKObjectType.workoutType()],
            read: [heartRate]
        )
    }

    func start() throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(
            healthStore: store,
            workoutConfiguration: configuration
        )
        // Solo pulso: el resto de métricas del entrenamiento (energía, etc.) gastan batería sin aportar nada.
        let heartRate = HKQuantityType(.heartRate)
        for type in dataSource.typesToCollect where type != heartRate {
            dataSource.disableCollection(for: type)
        }
        builder.dataSource = dataSource
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder

        let start = Date()
        session.startActivity(with: start)
        builder.beginCollection(withStart: start) { _, _ in }
    }

    func stop() {
        // Se sueltan las referencias ya: si el cierre llegara tarde y se empezara otra siesta
        // entretanto, antes borraba la sesión nueva y dejaba de llegar el pulso.
        guard let session, let builder else { return }
        self.session = nil
        self.builder = nil
        session.end()
        builder.endCollection(withEnd: Date()) { _, _ in
            builder.discardWorkout()
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.onError?(error.localizedDescription) }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard workoutBuilder === builder,  // ignora datos tardíos de una sesión ya cerrada
              collectedTypes.contains(heartRateType),
              let quantity = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity()
        else { return }

        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        DispatchQueue.main.async { self.onHeartRate?(bpm) }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
