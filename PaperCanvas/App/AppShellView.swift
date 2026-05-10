import SwiftUI

struct AppShellView: View {
    @State private var isReady = false

    var body: some View {
        ZStack {
            if isReady {
                LibraryView()
                    .transition(.opacity)
            } else {
                SplashView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: isReady)
        .task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            isReady = true
        }
    }
}

private struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.20, blue: 0.30),
                    Color(red: 0.10, green: 0.12, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: 128, height: 128)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 1)
                        )
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(pulse ? 1.05 : 0.95)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: pulse
                        )
                }

                VStack(spacing: 6) {
                    Text("PaperCanvas")
                        .font(AppType.display)
                        .foregroundStyle(.white)
                    Text("논문과 캔버스를 한 화면에")
                        .font(AppType.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.85))
                    .padding(.top, 8)
            }
        }
        .onAppear { pulse = true }
    }
}
