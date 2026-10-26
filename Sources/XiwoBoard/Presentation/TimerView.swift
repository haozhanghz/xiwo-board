import AppKit
import Combine
import SwiftUI

/// Classroom timer (计时器): countdown with presets, or a stopwatch.
struct TimerView: View {
    let close: () -> Void

    enum Mode: String, CaseIterable { case countdown = "倒计时", stopwatch = "正计时" }

    @State private var mode: Mode = .countdown
    @State private var total: TimeInterval = 180
    @State private var remaining: TimeInterval = 180
    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var lastTick = Date()
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                PillPicker(selection: $mode, options: Mode.allCases.map { ($0, $0.rawValue) })
                .frame(width: 150)
                .onChange(of: mode) { _, _ in reset() }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("关闭计时器")
            }
            HStack(spacing: 14) {
                // Hidden rather than removed, so the panel keeps its size while the timer runs.
                Button { adjust(-60) } label: { stepIcon("minus") }.buttonStyle(.plain).help("减 1 分钟")
                    .opacity(mode == .countdown && !running ? 1 : 0).disabled(mode != .countdown || running)
                Text(format(mode == .countdown ? remaining : elapsed))
                    .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(mode == .countdown && remaining <= 10 && running ? Color(red: 1, green: 0.45, blue: 0.42) : .primary)
                Button { adjust(60) } label: { stepIcon("plus") }.buttonStyle(.plain).help("加 1 分钟")
                    .opacity(mode == .countdown && !running ? 1 : 0).disabled(mode != .countdown || running)
            }
            .frame(minWidth: 300)
            if mode == .countdown && !running {
                HStack {
                    ForEach([30.0, 60, 180, 300, 600], id: \.self) { s in
                        Button { total = s; remaining = s } label: {
                            Text(s < 60 ? "\(Int(s))秒" : "\(Int(s / 60))分")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(total == s ? Theme.accent : .primary)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(total == s ? Theme.accent.opacity(0.2) : Color.white.opacity(0.08), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 12) {
                Button { running.toggle(); lastTick = Date() } label: {
                    Text(running ? "暂停" : "开始").frame(width: 92)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                Button { reset() } label: {
                    Text("重置").font(.system(size: 13)).padding(.horizontal, 14).frame(height: 30)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .presenterPanel(cornerRadius: 16)
        .environment(\.colorScheme, .dark)
        .padding(4)
        .fixedSize()
        .onReceive(ticker) { now in
            guard running else { return }
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            if mode == .countdown {
                remaining = max(0, remaining - dt)
                if remaining == 0 {
                    running = false
                    NSSound(named: "Glass")?.play()
                }
            } else {
                elapsed += dt
            }
        }
    }

    private func stepIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .semibold))
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }

    private func adjust(_ d: TimeInterval) {
        total = max(10, total + d)
        remaining = total
    }

    private func reset() {
        running = false
        remaining = total
        elapsed = 0
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
