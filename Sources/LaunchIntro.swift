import SwiftUI

/// The launch animation: "YOUSUF MIAH" in big letters, then (like a film studio's ident) the
/// letters fold away right to left into the Y and the M, which glide into the logo as its tile
/// springs up behind them with a ring of light, the play button and a sweep of shine; then the
/// name, and on into the app. Same timings as the Fire TV, phone and Samsung apps.
struct LaunchIntro: View {
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ns

    private static let name = Array("YOUSUF MIAH")
    private static let yAt = 0, mAt = 7

    @State private var built = Set<Int>()
    @State private var folded = Set<Int>()
    @State private var widths: [Int: CGFloat] = [:]
    @State private var push = false
    @State private var landed = false // the Y and M are in the logo

    @State private var tileIn = false
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
    private let inOut = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.36)

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x1A1240), Color(hex: 0x07060F), Color(hex: 0x030308)],
                           center: .center, startRadius: 0, endRadius: 700)
                .ignoresSafeArea()
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
                        if landed {
                            letter("Y").matchedGeometryEffect(id: "y", in: ns)
                            letter("M").matchedGeometryEffect(id: "m", in: ns)
                        }
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
                    .foregroundStyle(.white)
                    .padding(.top, 26)
                    .opacity(textIn ? 1 : 0)
                    .offset(y: textIn ? 0 : 12)
                Text("Developed by Yousuf Miah")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 6)
                    .opacity(textIn ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !landed { nameWord }
        }
        .opacity(leaving ? 0 : 1)
        .onAppear(perform: run)
    }

    /// "YOUSUF MIAH": each letter's width is measured so a folded one can close up to nothing.
    private var nameWord: some View {
        HStack(spacing: 0) {
            ForEach(0..<LaunchIntro.name.count, id: \.self) { i in
                let isAnchor = i == LaunchIntro.yAt || i == LaunchIntro.mAt
                let ch = LaunchIntro.name[i] == " " ? "\u{00A0}" : String(LaunchIntro.name[i])
                Group {
                    if isAnchor {
                        letter(ch).matchedGeometryEffect(id: i == LaunchIntro.yAt ? "y" : "m", in: ns)
                    } else {
                        letter(ch)
                    }
                }
                .fixedSize()
                .background(GeometryReader { g in Color.clear.preference(key: LetterWidths.self, value: [i: g.size.width]) })
                .scaleEffect(x: folded.contains(i) ? 0.05 : 1, y: 1, anchor: .leading)
                .frame(width: folded.contains(i) ? 0 : widths[i], alignment: .leading)
                .opacity(folded.contains(i) ? 0 : (built.contains(i) ? 1 : 0))
                .offset(y: built.contains(i) ? 0 : size * 0.15)
                .blur(radius: built.contains(i) ? 0 : 6)
                .zIndex(isAnchor ? 1 : 0)
            }
        }
        .onPreferenceChange(LetterWidths.self) { w in if widths.isEmpty { widths = w } }
        .scaleEffect(push ? 1.05 : 1)
        .shadow(color: Color(hex: 0x8A3FE6).opacity(0.55), radius: 18)
    }

    private func letter(_ s: String) -> some View {
        Text(s)
            .font(.system(size: size * 0.5, weight: .black))
            .foregroundStyle(.white)
            .shadow(color: Color(hex: 0x2A0A78).opacity(0.35), radius: 8, y: 5)
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    private func run() {
        if reduceMotion { // Reduce Motion: the finished logo, a short pause, then a fade
            landed = true; tileIn = true; playIn = true; textIn = true
            after(1.0) { withAnimation(.easeInOut(duration: 0.3)) { leaving = true } }
            after(1.35) { done() }
            return
        }
        // 1. the name builds in, letter by letter, slowly pushing in
        for i in 0..<LaunchIntro.name.count {
            after(0.06 + Double(i) * 0.038) { withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.52)) { _ = built.insert(i) } }
        }
        withAnimation(.timingCurve(0.3, 0, 0.7, 1, duration: 1.0)) { push = true }
        // 2. right to left, each letter folds into its Y or M (the gap closes as they go)
        let order = (0..<LaunchIntro.name.count).filter { $0 != LaunchIntro.yAt && $0 != LaunchIntro.mAt }.reversed()
        for (k, i) in order.enumerated() {
            after(1.0 + Double(k) * 0.042) { withAnimation(inOut) { _ = folded.insert(i) } }
        }
        // 3. the Y and the M glide into the logo, which builds behind them
        let glide = 1.0 + Double(order.count) * 0.042 + 0.12
        after(glide) { withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.62)) { landed = true } }
        let lock = glide + 0.56
        after(lock) { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { tileIn = true } }
        after(lock + 0.38) {
            ringOn = true
            withAnimation(.easeOut(duration: 0.12)) { bump = true }
            withAnimation(.easeOut(duration: 0.62)) { ringOut = true }
        }
        after(lock + 0.52) { withAnimation(.easeOut(duration: 0.25)) { bump = false } }
        after(lock + 0.42) { withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { playIn = true } }
        after(lock + 0.65) { withAnimation(.easeInOut(duration: 0.8)) { shine = true } }
        after(lock + 0.45) { withAnimation(.easeOut(duration: 0.5)) { textIn = true } }
        after(lock + 1.4) { withAnimation(.easeInOut(duration: 0.35)) { leaving = true } }
        after(lock + 1.8) { done() }
    }
}

/// Each letter's natural width (index → width).
private struct LetterWidths: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
}
