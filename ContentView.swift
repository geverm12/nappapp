import SwiftUI

struct ContentView: View {
    @StateObject private var nap = NapController()

    @AppStorage(SettingsKey.scanInterval) private var scanInterval = 60
    @AppStorage(SettingsKey.napDuration) private var napDuration = 20
    @AppStorage(SettingsKey.maxWait) private var maxWait = 45
    @AppStorage(SettingsKey.confirmSeconds) private var confirmSeconds = 180
    @AppStorage(SettingsKey.hrDrop) private var hrDrop = 5.0
    @AppStorage(SettingsKey.movementThreshold) private var movementThreshold = 0.02

    @Environment(\.scenePhase) private var scenePhase

    private var isActive: Bool { nap.phase != .idle }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    mainButton
                    if !nap.message.isEmpty {
                        Text(nap.message).font(.footnote).foregroundStyle(.red)
                    }
                }

                if isActive {
                    Section {
                        // Renderizado directo en línea para evitar conflictos de ObservedObject por consola
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                switch nap.phase {
                                case .calibrating:
                                    Label("Midiendo pulso de reposo…", systemImage: "waveform.path.ecg")
                                        .font(.headline)
                                case .monitoring:
                                    Label("Buscando sueño…", systemImage: "eye")
                                        .font(.headline)
                                case .asleep:
                                    Label("Durmiendo", systemImage: "moon.zzz.fill")
                                        .font(.headline).foregroundStyle(.indigo)
                                    if let wake = nap.wakeDate {
                                        Text("Alarma en").font(.footnote).foregroundStyle(.secondary)
                                        Text(wake, style: .timer).font(.title2.monospacedDigit())
                                    }
                                case .ringing:
                                    Label("¡Despierta!", systemImage: "alarm.fill")
                                        .font(.headline).foregroundStyle(.orange)
                                    Text(nap.ringReason).font(.footnote)
                                case .idle:
                                    EmptyView()
                                }
                            }

                            if let hr = nap.currentHR {
                                Label("Ahora: \(Int(hr)) lpm", systemImage: "heart.fill")
                                    .font(.footnote).foregroundStyle(.red)
                            }
                            if let resting = nap.baselineHR {
                                Label("Reposo: \(Int(resting)) lpm", systemImage: "heart")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Siesta") {
                    Stepper(value: $napDuration, in: 5...120, step: 5) {
                        labeled("Dormir", "\(napDuration) min")
                    }
                    Stepper(value: $scanInterval, in: 30...600, step: 30) {
                        labeled("Escanear cada", formatSeconds(scanInterval))
                    }
                    Stepper(value: $maxWait, in: 10...120, step: 5) {
                        labeled("Espera máx.", "\(maxWait) min")
                    }
                }
                .disabled(isActive)

                Section("Avanzado") {
                    Stepper(value: $confirmSeconds, in: 30...600, step: 30) {
                        labeled("Confirmar", formatSeconds(confirmSeconds))
                    }
                    Stepper(value: $hrDrop, in: 1...20, step: 1) {
                        labeled("Bajada pulso", "\(Int(hrDrop))%")
                    }
                    Stepper(value: $movementThreshold, in: 0.005...0.1, step: 0.005) {
                        labeled("Umbral mov.", String(format: "%.3f g", movementThreshold))
                    }
                }
                .disabled(isActive)
            }
            .navigationTitle("Siesta")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { nap.checkWake() }
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch nap.phase {
        case .idle:
            Button {
                Task { await nap.start() }
            } label: {
                Label("Empezar siesta", systemImage: "moon.zzz.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        case .ringing:
            Button {
                nap.stop()
            } label: {
                Label("Parar alarma", systemImage: "alarm.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        default:
            Button {
                nap.stop()
            } label: {
                Label("Cancelar siesta", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
    }

    private func formatSeconds(_ s: Int) -> String {
        s % 60 == 0 ? "\(s / 60) min" : "\(s) s"
    }
}
