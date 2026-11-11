import SwiftUI

struct WatchContentView: View {
    @ObservedObject var nap: NapController

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                switch nap.phase {
                case .idle:
                    Button {
                        Task { await nap.start() }
                    } label: {
                        Label("Empezar", systemImage: "moon.zzz.fill")
                    }
                    .tint(.indigo)
                case .ringing:
                    Button {
                        nap.stop()
                    } label: {
                        Label("Parar", systemImage: "alarm.fill")
                    }
                    .tint(.orange)
                default:
                    Button {
                        nap.stop()
                    } label: {
                        Label("Cancelar", systemImage: "xmark.circle.fill")
                    }
                    .tint(.red)
                }

                if let hr = nap.currentHR {
                    Text("\(Int(hr)) lpm")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
