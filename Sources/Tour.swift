import SwiftUI

/// The quick tour: shown once after you first sign in, and again from Settings → Show Tutorial
/// (the Mac version of the TV and phone apps' tips).
struct TourSheet: View {
    @EnvironmentObject var store: AppStore
    @State private var step = 0

    private struct Step {
        let icon: String
        let title: String
        let text: String
    }

    private let steps: [Step] = [
        Step(icon: "sidebar.left", title: "Getting around",
             text: "Home, Live TV, Movies, Series, Search, Downloads and Settings are in the sidebar on the left. Home has Continue Watching, your Queue, the UK Top 10 and picks based on what you watch."),
        Step(icon: "cursorarrow.click.2", title: "Right-click for more",
             text: "Right-click a film, series or episode to favourite it, add it to your Queue or mark it as watched. Right-click a category to favourite, rename or hide it."),
        Step(icon: "play.rectangle", title: "Watching",
             text: "Space plays and pauses, ← → skip 10 seconds, F goes full screen and P keeps it playing in a small window. Skip Intro appears during a series' opening titles; when an episode ends the next one follows."),
        Step(icon: "aspectratio", title: "Picture and subtitles",
             text: "While watching, use the buttons at the bottom right for audio, subtitles and the picture shape, or pinch the trackpad to fill the screen. Subtitle size and colour are in Settings."),
        Step(icon: "arrow.down.circle", title: "Downloads",
             text: "Download a film, an episode or a whole season from its page to watch without streaming. They're listed on the Downloads page."),
    ]

    var body: some View {
        let s = steps[step]
        VStack(spacing: 18) {
            Image(systemName: s.icon)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(height: 56)
                .id(step)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            Text(s.title).font(.system(size: 24, weight: .bold))
            Text(s.text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(width: 420, height: 96, alignment: .top)
            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i == step ? Theme.accent : Theme.cardHi).frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            HStack {
                Button("Skip") { store.finishTour() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { withAnimation(Theme.ease) { step -= 1 } } }
                Button(step == steps.count - 1 ? "Done" : "Next") {
                    if step == steps.count - 1 { store.finishTour() } else { withAnimation(Theme.ease) { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(30)
        .frame(width: 500)
        .animation(Theme.ease, value: step)
    }
}
