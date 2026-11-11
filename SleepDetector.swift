import Foundation

/// Resumen de lo medido entre dos escaneos.
struct ScanSample {
    /// Pulso medio (lpm) del intervalo, o nil si no hubo lecturas.
    var avgHR: Double?
    /// Movimiento medio (g, sin gravedad) del intervalo.
    var motionMean: Double
}

/// Decide si el usuario se ha dormido a partir de pulso + movimiento.
///
/// Regla: un escaneo es "tranquilo" si el movimiento medio es bajo Y el pulso
/// está por debajo del pulso de reposo en al menos `hrDropPercent`.
/// Si no hay lecturas de pulso (permiso denegado, correa floja), decide solo por movimiento.
/// Se da por dormido tras `requiredQuietScans` escaneos tranquilos consecutivos.
struct SleepDetector {
    let config: NapConfig
    private(set) var baselineHR: Double?
    private var quietScans = 0

    init(config: NapConfig) {
        self.config = config
    }

    var requiredQuietScans: Int {
        let n = Double(config.confirmSeconds) / Double(config.scanIntervalSeconds)
        return max(1, Int(n.rounded(.up)))
    }

    /// Peso de cada nueva medida en el pulso de reposo (media móvil exponencial).
    /// Sube rápido pero baja muy despacio: al dormirte el pulso cae de forma gradual,
    /// y si la referencia bajara al mismo ritmo nunca se llegaría a la caída exigida.
    private static let baselineRise = 0.2
    private static let baselineFall = 0.05

    mutating func setBaseline(_ hr: Double?) {
        baselineHR = hr
    }

    /// Devuelve true cuando se considera que el usuario está dormido.
    ///
    /// Mientras el usuario sigue despierto y quieto, el pulso de reposo se va
    /// actualizando con cada escaneo. Deja de actualizarse en cuanto el pulso
    /// entra en la "zona de sueño", para que la bajada gradual no arrastre la referencia.
    mutating func evaluate(_ scan: ScanSample) -> Bool {
        let movementQuiet = scan.motionMean < config.movementThreshold

        // Movimiento claro: se reinicia la cuenta (el pulso no vale como reposo).
        guard movementQuiet else {
            quietScans = 0
            return false
        }

        // Sin referencia inicial: la primera lectura válida la fija.
        if baselineHR == nil, let hr = scan.avgHR {
            baselineHR = hr
            return false
        }

        var hrQuiet = true
        if let baseline = baselineHR {
            guard let hr = scan.avgHR else {
                // Sin lectura de pulso: ni suma ni resta.
                return false
            }
            hrQuiet = hr <= baseline * (1 - config.hrDropPercent / 100)
            if !hrQuiet {
                // Despierto y en reposo: refresca el pulso de reposo.
                let a = hr > baseline ? Self.baselineRise : Self.baselineFall
                baselineHR = baseline + (hr - baseline) * a
            }
        }

        if hrQuiet {
            quietScans += 1
        } else {
            quietScans = 0
        }
        return quietScans >= requiredQuietScans
    }

    var progress: Int { quietScans }
}
