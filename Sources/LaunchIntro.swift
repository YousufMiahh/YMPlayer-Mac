import SwiftUI

/// The launch animation: the logo builds itself. The tile springs in, the Y flies in from the left
/// and the M from the right, they lock together with a flash and a ring, the play button pops up
/// and a sweep of light crosses the tile; then the name, and on into the app.
struct LaunchIntro: View {
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tileIn = false
    @State private var lettersIn = false
    @State private var bump = false
    @State private var ringOn = false
    @State private var ringOut = false
    @State private var playIn = false
    @State private var shine = false
    @State private var textIn = false
    @State private var leaving = false

    private let size: CGFloat = 170
    private let gradient = LinearGradient(colors: [Color(hex: 0x5153FB), Color(hex: 0x8A3FE6), Color(hex: 0xF35E80)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        GeometryReader { geo in
            let far = geo.size.width * 0.6
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 4)
                            .frame(width: size / 3, height: size / 3)
                            .scaleEffect(ringOut ? 5 : 0.4)
                            .opacity(ringOut ? 0 : (ringOn ? 0.95 : 0))
                        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                            .fill(gradient)
                            .overlay(
                                Rectangle()
                                    .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: size * 0.4, height: size * 2)
                                    .rotationEffect(.degrees(25))
                                    .offset(x: shine ? size * 1.1 : -size * 1.1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                            .frame(width: size, height: size)
                            .brightness(bump ? 0.15 : 0)
                            .shadow(color: Color(hex: 0x5028C8).opacity(0.45), radius: 24, y: 14)
                            .scaleEffect(tileIn ? (bump ? 1.08 : 1) : 0.35)
                            .rotationEffect(.degrees(tileIn ? 0 : -14))
                            .opacity(tileIn ? 1 : 0)
                        HStack(spacing: size / 48) {
                            letter("Y", from: -far)
                            letter("M", from: far)
                        }
                        .offset(y: -size * 0.04)
                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.1, weight: .bold))
                            .foregroundStyle(.white)
                            .scaleEffect(playIn ? 1 : 0.01)
                            .opacity(playIn ? 1 : 0)
                            .offset(y: size * 0.3 + (playIn ? 0 : size / 19))
                    }
                    .frame(width: size, height: size)
                    Text("YM Player")
                        .font(.system(size: 32, weight: .bold))
                        .padding(.top, 26)
                        .opacity(textIn ? 1 : 0)
                        .offset(y: textIn ? 0 : 12)
                    Text("Developed by Yousuf Miah")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        .opacity(textIn ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opacity(leaving ? 0 : 1)
        .onAppear(perform: run)
    }

    private func letter(_ s: String, from: CGFloat) -> some View {
        Text(s)
            .font(.system(size: size * 0.5, weight: .black))
            .foregroundStyle(.white)
            .shadow(color: Color(hex: 0x2A0A78).opacity(0.35), radius: 8, y: 5)
            .scaleEffect(x: lettersIn ? 1 : 1.6, y: 1)
            .blur(radius: lettersIn ? 0 : 6)
            .offset(x: lettersIn ? 0 : from)
            .opacity(lettersIn ? 1 : 0)
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    private func run() {
        if reduceMotion { // Reduce Motion: the finished logo, a short pause, then a fade
            tileIn = true; lettersIn = true; playIn = true; textIn = true
            after(1.0) { withAnimation(.easeInOut(duration: 0.3)) { leaving = true } }
            after(1.35) { done() }
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { tileIn = true }
        after(0.16) { withAnimation(.spring(response: 0.48, dampingFraction: 0.68)) { lettersIn = true } }
        after(0.64) {
            ringOn = true
            withAnimation(.easeOut(duration: 0.12)) { bump = true }
            withAnimation(.easeOut(duration: 0.62)) { ringOut = true }
        }
        after(0.78) { withAnimation(.easeOut(duration: 0.25)) { bump = false } }
        after(0.82) { withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { playIn = true } }
        after(1.0) { withAnimation(.easeInOut(duration: 0.8)) { shine = true } }
        after(1.05) { withAnimation(.easeOut(duration: 0.5)) { textIn = true } }
        after(2.3) { withAnimation(.easeInOut(duration: 0.35)) { leaving = true } }
        after(2.7) { done() }
    }
}
