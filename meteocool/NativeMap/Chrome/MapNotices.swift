//
//  MapNotices.swift
//  meteocool
//
//  core's "Back to now" pill, the strips above the tray (`DismissableStrip`
//  with `SwipeDock`, the one notice of `lib/noticeQueue.ts`) and its toasts.
//

import SwiftUI

/// "Back to now ⟲": shown off the live frame or while playing; lingers
/// 120 ms when the needle comes back so a drag past now does not flicker it.
/// Not in a past window, whose tab at the top is the way back (`ArchiveTab`).
struct BackToNowPill: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    /// Site mode has no timeline to go back along.
    @ObservedObject var site: SiteSweepState
    /// Its host measured again: grown from the empty placeholder it was
    /// laid out at, or the pill is squeezed to its icon and out of reach.
    var resized: () -> Void = {}
    @State private var shown = false

    private var theme: ChromeTheme { ChromeTheme(dark: model.isDark) }
    private var wanted: Bool {
        !player.timeline.steps.isEmpty && (player.playing || !player.isLive) && !player.grabbed
            && !model.stale && model.capability == .radar && model.window == nil
    }

    var body: some View {
        // Never empty: a host laid out at zero size does not grow back.
        ZStack {
            Color.clear.frame(width: 1, height: 32)
            if shown {
                Button(action: player.showLive) {
                    HStack(spacing: 6) {
                        Text(CoreStrings.t("chrome.playback.back_to_latest"))
                            .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                            .tracking(-0.13)
                            .foregroundStyle(theme.text)
                        Image(systemName: "clock.arrow.circlepath")
                            .scaledFont(12, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(theme.accent)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .chromeGlass(theme, in: Capsule())
                }
                .buttonStyle(PressScale())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("nativeMap.backToNow")
            }
        }
        .environment(\.colorScheme, theme.colorScheme)
        .animation(.easeOut(duration: 0.2), value: shown)
        .onChange(of: shown) { _, _ in DispatchQueue.main.async { resized() } }
        .task(id: wanted) {
            if wanted {
                shown = true
            } else {
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { shown = false }
            }
        }
    }
}

/// A glass bar above the tray that swipes aside to one action under it, as
/// a notification does (`SwipeDock`): a short pull parks it with the action
/// showing, a long one throws it off the edge. A tap on a `tappable` bar
/// (not on its buttons) raises `tap`.
struct SwipeDock<Content: View>: View {
    let action: String
    let theme: ChromeTheme
    var height: CGFloat = ChromeTheme.stripHeight
    var strong = false
    var tap: (() -> Void)?
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var parked = false

    /// core's swipe constants (`lib/swipeAway.ts`).
    private static var detent: CGFloat { 96 }
    private static var give: CGFloat { 0.7 }
    private static var commit: CGFloat { 0.45 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .trailing) {
                // The action under the bar.
                RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous)
                    .fill(theme.redVeil)
                    .overlay(alignment: .trailing) {
                        Button(action, action: hide)
                            .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(-offset > width * Self.commit ? .white : theme.red)
                            .frame(width: max(Self.detent, -offset))
                    }
                    .opacity(offset < 0 ? 1 : 0)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if parked {
                            withAnimation(.spring(duration: 0.34)) { offset = 0 }
                            parked = false
                        } else {
                            tap?()
                        }
                    }
                    .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous), strong: strong)
                    .offset(x: offset)
                    .gesture(DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            let pull = min(0, value.translation.width + (parked ? -Self.detent : 0))
                            offset = pull > -Self.detent ? pull : -Self.detent + (pull + Self.detent) * Self.give
                        }
                        .onEnded { _ in
                            if -offset > width * Self.commit {
                                withAnimation(.spring(duration: 0.34)) { offset = -width }
                                hide()
                            } else if -offset >= 48 {
                                withAnimation(.spring(duration: 0.34)) { offset = -Self.detent }
                                parked = true
                            } else {
                                withAnimation(.spring(duration: 0.34)) { offset = 0 }
                                parked = false
                            }
                        })
            }
        }
        .frame(height: height)
        .environment(\.colorScheme, theme.colorScheme)
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.2)) { dismiss() }
    }
}

/// A strip above the tray: a title, a body, and two ways to hide it, the
/// close button or a swipe to the left (`DismissableStrip`).
struct DismissableStrip<Content: View>: View {
    let title: String
    let theme: ChromeTheme
    let dismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        SwipeDock(action: CoreStrings.t("hide"), theme: theme, dismiss: dismiss) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(title)
                        .scaledFont(13, weight: .bold, relativeTo: .footnote)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(.easeIn(duration: 0.2)) { dismiss() }
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(theme.text3)
                            .frame(width: 44, height: 30)
                    }
                    .accessibilityLabel(CoreStrings.t("close"))
                }
                .padding(.leading, 16)
                content()
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
    }
}

/// The one notice in the slot above the tray (`lib/noticeQueue.ts`): ours
/// for this view first, then what the map finds for itself. The dry outlook,
/// last in the queue, keeps its own strip and gives way to any of these.
struct NoticeStrips: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    @ObservedObject var notices: NoticeState

    private var theme: ChromeTheme { ChromeTheme(dark: model.isDark) }

    var body: some View {
        VStack(spacing: 0) {
            if let shown = notices.shown {
                let words = Self.words(shown)
                DismissableStrip(title: words.title, theme: theme, dismiss: { notices.dismiss(shown) }) {
                    Text(words.body).notice(theme)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nativeMap.strip.\(words.id)")
                // One replacing another leaves and comes in as a strip of its own.
                .id(NoticeQueue.dismissalKey(shown))
            }
        }
        .padding(.horizontal, ChromeTheme.gutter)
    }

    /// A strip's heading and text by what it is about, and its identifier.
    static func words(_ notice: NoticeQueue.Queued) -> (title: String, body: String, id: String) {
        switch notice {
        case .ours(let ours):
            return (CoreStrings.t(ours.level == .warning ? "notice_warning" : "notice_info"), ours.text, "notice")
        case .condition(.noCoverage):
            return (CoreStrings.t("radar_no_coverage"), CoreStrings.plain("radar_no_coverage_body"), "noRadar")
        case .condition(.radarStopped):
            return (CoreStrings.t("radar_feed_stopped"), CoreStrings.plain("radar_feed_stopped_body"), "feedStopped")
        case .condition(.forecastStopped):
            return (CoreStrings.t("forecast_feed_stopped"), CoreStrings.plain("forecast_feed_stopped_body"), "forecastStopped")
        case .condition(.noForecast), .condition(.dryOutlook):
            return (CoreStrings.t("forecast_no_coverage"), CoreStrings.plain("forecast_no_coverage_body_nowcast"), "noForecast")
        }
    }
}

private extension Text {
    @MainActor func notice(_ theme: ChromeTheme) -> some View {
        scaledFont(12, relativeTo: .caption).lineSpacing(2).foregroundStyle(theme.text2).lineLimit(4)
    }
}

/// What applies above the tray, and what the reader has hidden: a
/// condition comes back once it has cleared and returns; ours stay hidden by
/// id for the session, a map built again included (`lib/noticeQueue.ts`).
@MainActor
final class NoticeState: ObservableObject {
    /// The notices dismissed this session.
    private static var sessionDismissed = Set<String>()

    /// What applies now; the dry outlook is its own strip's to judge.
    @Published private(set) var candidates = NoticeQueue.Candidates()
    @Published private(set) var dismissed = NoticeState.sessionDismissed
    @Published var radarShown = true

    /// The one shown, if any.
    var shown: NoticeQueue.Queued? { radarShown ? NoticeQueue.next(candidates, dismissed: dismissed) : nil }

    func update(_ next: NoticeQueue.Candidates) {
        if next != candidates { candidates = next }
        let kept = NoticeQueue.rearmed(dismissed, next)
        if kept != dismissed { keep(kept) }
    }

    func dismiss(_ notice: NoticeQueue.Queued) {
        keep(dismissed.union([NoticeQueue.dismissalKey(notice)]))
    }

    private func keep(_ next: Set<String>) {
        dismissed = next
        Self.sessionDismissed = next
    }
}

/// A toast at the top (core's `Toast.ts`): a message that goes after a while.
struct MapToast: View {
    let text: String
    let symbol: String
    let theme: ChromeTheme
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Decoration: the text says it all.
            Image(systemName: symbol).scaledFont(18, relativeTo: .body).foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            Text(text).scaledFont(13, relativeTo: .footnote).lineSpacing(3).foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").scaledFont(12, weight: .semibold, relativeTo: .caption).foregroundStyle(theme.text3)
            }
            .accessibilityLabel(CoreStrings.t("close"))
        }
        .padding(12)
        .frame(maxWidth: 448)
        .chromeGlass(theme, in: RoundedRectangle(cornerRadius: 18, style: .continuous), strong: true)
        .environment(\.colorScheme, theme.colorScheme)
        // One toast, its words and its close button inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.toast")
    }
}
