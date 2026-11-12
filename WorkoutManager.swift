import HealthKit

nonisolated final class WorkoutManager: NSObject, @unchecked Sendable {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    var onHeartRate: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            let errorMsg = "HealthKit no está disponible en este dispositivo."
            await MainActor.run { self.onError?(errorMsg) }
            throw NSError(domain: "WorkoutManager", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            let errorMsg = "No se pudo inicializar el tipo de ritmo cardíaco."
            await MainActor.run { self.onError?(errorMsg) }
            throw NSError(domain: "WorkoutManager", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let typesToShare: Set = [
            HKObjectType.workoutType()
        ]
        
        let typesToRead: Set = [
            heartRateType,
            HKObjectType.workoutType()
        ]

        do {
            try await store.requestAuthorization(toShare: typesToShare, read: typesToRead)
        } catch {
            await MainActor.run { self.onError?("Error de autorización HealthKit: \(error.localizedDescription)") }
            throw error
        }
    }

    func start() async {
        do {
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
            
            // Uso del callback de completado requerido por el SDK de watchOS
            builder.beginCollection(withStart: startDate) { success, error in
                if let error = error {
                    Task { @MainActor in
                        self.onError?("Error al iniciar colección: \(error.localizedDescription)")
                    }
                }
            }
            
        } catch {
            await MainActor.run {
                self.onError?("No se pudo iniciar el entrenamiento: \(error.localizedDescription)")
            }
        }
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
        Task { @MainActor in self.onError?(error.localizedDescription) }
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
        Task { @MainActor in self.onHeartRate?(bpm) }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
