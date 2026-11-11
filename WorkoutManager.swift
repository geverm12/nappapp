import HealthKit

nonisolated final class WorkoutManager: NSObject, @unchecked Sendable {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    var onHeartRate: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    func requestAuthorization() async throws {
        // Verificamos explícitamente que HealthKit esté disponible en este dispositivo (por ejemplo, iPad no tiene sensores de pulso nativos)
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "WorkoutManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "HealthKit no está disponible en este dispositivo."])
        }

        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else {
            throw NSError(domain: "WorkoutManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No se pudieron inicializar los tipos de HealthKit."])
        }

        let typesToShare: Set = [HKObjectType.workoutType()]
        let typesToRead: Set = [heartRateType, activeEnergyType, HKObjectType.workoutType()]

        // Solicitamos formalmente el acceso al almacenamiento de salud
        try await store.requestAuthorization(toShare: typesToShare, read: typesToRead)
    }

    func start() async throws {
        // Pedimos los permisos obligatoriamente antes de configurar la sesión
        try await requestAuthorization()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(
            healthStore: store,
            workoutConfiguration: configuration
        )
        
        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        for type in dataSource.typesToCollect where type != heartRateType {
            dataSource.disableCollection(for: type)
        }
        builder.dataSource = dataSource
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder

        let startDate = Date()
        session.startActivity(with: startDate)
        builder.beginCollection(withStart: startDate) { _, _ in }
    }

    func stop() {
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
        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        guard workoutBuilder === builder,
              collectedTypes.contains(heartRateType),
              let quantity = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity()
        else { return }

        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        DispatchQueue.main.async { self.onHeartRate?(bpm) }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
