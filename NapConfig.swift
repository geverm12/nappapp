import Foundation

/// Claves de UserDefaults (compartidas con @AppStorage en las vistas).
enum SettingsKey {
    static let scanInterval = "scanIntervalSeconds"
    static let napDuration = "napDurationMinutes"
    static let maxWait = "maxWaitMinutes"
    static let confirmSeconds = "confirmSeconds"
    static let hrDrop = "hrDropPercent"
    static let movementThreshold = "movementThreshold"
}

/// Ajustes de la siesta. Se leen de UserDefaults al empezar cada siesta.
struct NapConfig {
    /// Cada cuántos segundos se evalúa si te has dormido.
    var scanIntervalSeconds: Int
    /// Minutos de sueño deseados desde que te quedas dormido.
    var napDurationMinutes: Int
    /// Si no te duermes en este tiempo, suena la alarma igualmente.
    var maxWaitMinutes: Int
    /// Segundos seguidos de "calma" necesarios para dar el sueño por confirmado.
    var confirmSeconds: Int
    /// Caída mínima del pulso respecto al inicial (en %) para considerar sueño.
    var hrDropPercent: Double
    /// Movimiento medio máximo (en g) para considerar reposo.
    var movementThreshold: Double

    /// Segundos iniciales para medir el pulso "de reposo despierto".
    static let calibrationSeconds = 120

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.scanInterval: 60,
            SettingsKey.napDuration: 20,
            SettingsKey.maxWait: 45,
            SettingsKey.confirmSeconds: 180,
            SettingsKey.hrDrop: 5.0,
            SettingsKey.movementThreshold: 0.02,
        ])
    }

    static func load() -> NapConfig {
        let d = UserDefaults.standard
        return NapConfig(
            scanIntervalSeconds: max(10, d.integer(forKey: SettingsKey.scanInterval)),
            napDurationMinutes: max(1, d.integer(forKey: SettingsKey.napDuration)),
            maxWaitMinutes: max(1, d.integer(forKey: SettingsKey.maxWait)),
            confirmSeconds: max(10, d.integer(forKey: SettingsKey.confirmSeconds)),
            hrDropPercent: d.double(forKey: SettingsKey.hrDrop),
            movementThreshold: d.double(forKey: SettingsKey.movementThreshold)
        )
    }
}
