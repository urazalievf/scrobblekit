import ScrobbleCore
import SwiftUI

/// First launch: what ScrobbleKit does, what iOS lets it catch (honestly),
/// and the Apple Music permission.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    let onFinish: () -> Void

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                limits.tag(1)
                permission.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .animation(.smooth, value: page)

            Button {
                if page < pageCount - 1 {
                    withAnimation(.smooth) { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pageCount - 1 ? "Continue" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var welcome: some View {
        OnboardingPage(symbol: "waveform", title: "ScrobbleKit") {
            Text("Sends what you play in Apple Music to Last.fm and ListenBrainz. Every play goes to both.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var limits: some View {
        OnboardingPage(symbol: "clock.arrow.circlepath", title: "What iPhone allows") {
            VStack(alignment: .leading, spacing: 14) {
                Point(symbol: "bolt.fill", title: "While the app is open",
                      text: "Plays are caught in real time.")
                Point(symbol: "moon.zzz.fill", title: "In the background",
                      text: "iOS lets ScrobbleKit check Recently Played every so often, on its own schedule.")
                Point(symbol: "arrow.triangle.2.circlepath", title: "With a Shortcut",
                      text: "An hourly “Sync Scrobbles” automation fills the gaps.")
                Text("Expect roughly 85–95% of plays. Replaying the same song between check-ins can be missed. ScrobbleKit for Mac catches everything played on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var permission: some View {
        OnboardingPage(symbol: "music.note", title: "Apple Music access") {
            VStack(spacing: 16) {
                Text("ScrobbleKit needs to see what you play. Nothing leaves your phone except the scrobbles you send to Last.fm and ListenBrainz.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if model.musicAuthorized {
                    Label("Access allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Allow Access") { Task { await model.requestMusicAccess() } }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
                Text("Connect Last.fm and ListenBrainz next, from Settings (the gear on the home screen).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .animation(.smooth, value: model.musicAuthorized)
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let title: String
    let content: Content

    init(symbol: String, title: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.22, blue: 0.40), Color(red: 0.36, green: 0.32, blue: 0.92)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .shadow(color: .pink.opacity(0.3), radius: 16, y: 8)
            Text(title)
                .font(.largeTitle.bold())
            content
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}

private struct Point: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
