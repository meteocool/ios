//
//  StatusPill.swift
//  meteocool
//
//  core's status pill (`LiveIndicator.svelte`) and Connection Details
//  (`ConnectionInfo.svelte`).
//

import Network
import SwiftUI

/// "● Latest", the frame's time, or what is wrong with the connection,
/// centred on the top line. A tap opens Connection Details.
struct StatusPill: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    @ObservedObject var monitor: ConnectionMonitor
    let open: () -> Void
    /// Bumped on every foreground or wake: a dimmed "Latest" brightens again.
    let wakes: Int

    @State private var dimmed = false
    @State private var blinkOn = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: ChromeTheme { ChromeTheme(dark: model.isDark) }
    private var state: PillState {
        monitor.pillState(live: player.isLive, shownStep: player.step, replay: player.timeline.replay,
                          radarStale: model.stale, hasTimeline: !player.timeline.steps.isEmpty)
    }

    var body: some View {
        let state = self.state
        // Never empty: a host laid out at zero size does not grow back.
        HStack {
            if state == .none {
                Color.clear.frame(width: 1, height: 44)
            } else {
                Button(action: open) {
                    HStack(spacing: 6) {
                        if case .time(let step) = state {
                            Text(Self.clock(step))
                                .scaledFont(13, weight: .semibold, relativeTo: .footnote, digits: true)
                        } else {
                            dot(state)
                            Text(title(state)).scaledFont(12, weight: .semibold, relativeTo: .caption).tracking(0.12)
                        }
                    }
                    .foregroundStyle(theme.text)
                    .padding(.leading, isTime(state) ? 12 : 10)
                    .padding(.trailing, 12)
                    .frame(height: ChromeTheme.pillHeight)
                    .chromeGlass(theme, in: Capsule(), interactive: true)
                    .opacity(state == .live && dimmed ? 0.5 : 1)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(isTime(state) ? Self.clock(player.step ?? 0) : title(state))
                .accessibilityHint(CoreStrings.t("connection_details"))
                .accessibilityIdentifier("nativeMap.pill")
            }
        }
        .frame(height: 44)
        .fixedSize()
        .environment(\.colorScheme, theme.colorScheme)
        .task(id: wakes) { await dimAfterAWhile() }
        .task { await blink() }
    }

    private func isTime(_ state: PillState) -> Bool {
        if case .time = state { return true }
        return false
    }

    private func title(_ state: PillState) -> String {
        switch state {
        case .offline: return CoreStrings.t("offline")
        case .catchingUp: return CoreStrings.t("catching_up")
        case .degraded: return CoreStrings.t("degraded")
        case .stale: return CoreStrings.t("outdated")
        case .slow: return CoreStrings.t("slow_connection")
        case .demo: return CoreStrings.t("demo")
        case .live: return CoreStrings.t("latest")
        case .time, .none: return ""
        }
    }

    @ViewBuilder
    private func dot(_ state: PillState) -> some View {
        let colour: Color = switch state {
        case .live: blinkOn || reduceMotion ? theme.red : theme.redDim
        case .offline: theme.red
        case .slow, .stale, .degraded: theme.orange
        case .demo, .catchingUp: theme.accent
        default: .clear
        }
        Circle()
            .fill(colour)
            .frame(width: 7, height: 7)
            .opacity(state == .catchingUp && !reduceMotion ? (blinkOn ? 1 : 0.3) : 1)
            .animation(.easeInOut(duration: state == .catchingUp ? 1.2 : 0.3), value: blinkOn)
    }

    /// A live pill dims to half after three seconds (`LiveIndicator`).
    private func dimAfterAWhile() async {
        dimmed = false
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        withAnimation(.linear(duration: 0.5)) { dimmed = true }
    }

    /// The live dot alternates every second.
    private func blink() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            blinkOn.toggle()
        }
    }

    /// `HH:mm`, 24-hour, in the device's zone.
    static func clock(_ step: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(step)))
    }
}

/// What the connection and the radar are doing, for the curious and for
/// bug reports (`ConnectionInfo.svelte`), refreshed every two seconds.
struct ConnectionDetails: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    @ObservedObject var monitor: ConnectionMonitor
    let close: () -> Void

    private func d(_ key: String, _ args: [String: Any] = [:]) -> String { CoreStrings.t("chrome.diagnostics.\(key)", args) }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                List {
                    Section(d("timesteps")) { timesteps }
                    Section(d("section.connection")) {
                        row(d("connection_state"), monitor.connection.rawValue)
                        row(d("online"), monitor.offlinePath ? d("false") : d("true"))
                        row(d("save_data"), monitor.constrained ? d("true") : d("false"))
                        row(d("reads_as_slow"), monitor.slow ? d("yes") : d("no"))
                        row(d("poke_channel"), model.connected ? d("connected") : d("disconnected"))
                        row(d("calls_in_flight"), "\(NetworkLog.shared.snapshot.inFlight)")
                        row(d("last_answer"), ago(NetworkLog.shared.snapshot.records.last { $0.status != nil }?.time, now: context.date))
                    }
                    Section(d("section.freshness")) {
                        row(d("newest_frame_built"), ago(player.timeline.now.map { Date(timeIntervalSince1970: TimeInterval($0)) }, now: context.date))
                        if let server = model.serverTime {
                            row(d("server_clock"), "\(Int(context.date.timeIntervalSince(server)))s")
                        }
                        row(d("state"), model.stale ? CoreStrings.t("outdated") : d("ok"))
                    }
                    Section(d("section.forecast_grid")) {
                        let timeline = player.timeline
                        row(d("steps"), "\(timeline.steps.count)")
                        let observed = timeline.steps.filter { timeline.layers[$0]?.isEmpty == false && !timeline.isForecast($0) }.count
                        let forecast = timeline.steps.filter { timeline.isForecast($0) && timeline.isPlayable($0) }.count
                        row(d("filled"), d("filled_value", ["filled": observed + forecast, "obs": observed, "forecast": forecast]))
                        row(d("with_reflectivity"), "\(timeline.dbz.count)")
                        if let last = timeline.lastPlayable { row(d("playable_to"), player.offsetLabel(last)) }
                    }
                    Section(d("latency_by_service")) { latency(now: context.date) }
                    Section(d("section.degraded")) {
                        row(d("state"), monitor.degradedReasons.isEmpty ? d("ok") : d("degraded"))
                        ForEach(monitor.degradedReasons, id: \.name) { reason in row(reason.name, reason.reason) }
                    }
                    Section(d("section.api_errors")) {
                        let failing = ConnectionRules.failingEndpoints(NetworkLog.shared.snapshot.records, now: context.date)
                        row(d("failing_now"), failing.isEmpty ? d("none") : failing.joined(separator: ", "))
                    }
                    Section(d("section.context")) {
                        row(d("capability"), model.capability.rawValue)
                        row(d("chrome_scheme"), model.isDark ? "dark" : "light")
                        row(d("position"), model.userLocation.map { String(format: "%.3f, %.3f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? d("not_shared"))
                    }
                }
                .scaledFont(13, relativeTo: .footnote)
            }
            .navigationTitle(CoreStrings.t("connection_details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                }
            }
        }
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.connectionDetails")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }
    }

    private func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return d("never") }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return d("ago_seconds", ["n": seconds]) }
        if seconds < 3600 { return d("ago_minutes", ["n": seconds / 60]) }
        return d("ago_hours", ["n": seconds / 3600])
    }

    /// One cell per step: observed, forecast, or missing.
    private var timesteps: some View {
        let timeline = player.timeline
        return HStack(spacing: 2) {
            ForEach(timeline.steps, id: \.self) { step in
                let has = timeline.layers[step]?.isEmpty == false && timeline.isPlayable(step)
                RoundedRectangle(cornerRadius: 2)
                    .fill(!has ? Color.red.opacity(0.25) : timeline.isForecast(step) ? Color.accentColor.opacity(0.3) : Color.accentColor)
                    .frame(height: 16)
            }
        }
    }

    @ViewBuilder
    private func latency(now: Date) -> some View {
        let records = NetworkLog.shared.snapshot.records.filter { now.timeIntervalSince($0.time) < 600 }
        let services = ["radar_grid", "api_other", "radar_tiles", "lightning", "mesocyclones", "geocoder"]
        ForEach(services, id: \.self) { service in
            let durations = records.filter { $0.service == service && $0.status != nil }.map(\.duration)
            if !durations.isEmpty {
                HStack {
                    Text(d("service.\(service)"))
                    Spacer()
                    Text("n \(durations.count) · \(d("median")) \(Int((ConnectionRules.quantile(durations, 0.5) ?? 0) * 1000)) ms · p95 \(Int((ConnectionRules.quantile(durations, 0.95) ?? 0) * 1000)) ms")
                        .scaledFont(11, relativeTo: .caption2, digits: true)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
