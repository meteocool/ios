//
//  StatusSheet.swift
//  meteocool
//
//  What the status pill says, in sentences (core's `StatusSheet.svelte`).
//

import SwiftUI

/// Opened by the pill. In order: our notices for this view; the connection,
/// when it is not fine (offline, catching up, degraded with its reasons,
/// slow, the socket gone); one row per thing late on screen as the backend
/// judges it, worst first; and when nothing is, one line saying everything
/// is arriving. Connection Details is behind the last row. A sheet with
/// detents rather than core's card under the pill: the map stays in view
/// above it at its medium height.
struct StatusSheet: View {
    @ObservedObject var player: RadarPlayer
    @ObservedObject var model: NativeMapModel
    @ObservedObject var monitor: ConnectionMonitor
    let close: () -> Void

    var body: some View {
        NavigationStack {
            // Ticked so "3 min old" does not stand still.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                List {
                    ForEach(model.statusVerdict?.notices ?? [], id: \.id) { notice in
                        Section {
                            Text(notice.text)
                        } header: {
                            Text(CoreStrings.t(notice.level == .warning ? "notice_warning" : "notice_info"))
                                .foregroundStyle(notice.level == .warning ? Color.orange : Color.secondary)
                        }
                        .accessibilityIdentifier("nativeMap.status.notice")
                    }
                    if !connectionLines.isEmpty {
                        Section(CoreStrings.t("status.connection.title")) {
                            ForEach(connectionLines, id: \.self) { Text($0) }
                        }
                        .accessibilityIdentifier("nativeMap.status.connection")
                    }
                    late(now: context.date)
                    Section {
                        NavigationLink(CoreStrings.t("connection_details")) {
                            // The sheet's Close on every level of it.
                            ConnectionDetails(player: player, model: model, monitor: monitor)
                                .toolbar { closeButton }
                        }
                        .accessibilityIdentifier("nativeMap.status.details")
                        // A row to tap, not text to copy.
                        .textSelection(.disabled)
                    }
                }
                // Its sentences can be copied with a long press (core's `.mc-selectable`).
                .textSelection(.enabled)
            }
            .navigationTitle(CoreStrings.t("status.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
        }
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.statusSheet")
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: close) { Image(systemName: "xmark") }
                .accessibilityLabel(CoreStrings.t("close"))
                .accessibilityIdentifier("nativeMap.status.close")
        }
    }

    /// What is late on screen, or that everything arrives, or the map's own
    /// rule's word without a verdict.
    @ViewBuilder
    private func late(now: Date) -> some View {
        if let verdict = model.statusVerdict {
            if !verdict.affected.isEmpty {
                Section(CoreStrings.t("status.late")) {
                    ForEach(verdict.affected, id: \.component.key) { late in
                        LabeledContent {
                            Text(state(late.component))
                                .foregroundStyle(late.component.state == .down ? Color.orange : Color.secondary)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text(what(late.component)).fontWeight(.semibold)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("nativeMap.status.late.\(late.component.key)")
                    }
                }
            } else {
                Section {
                    Text(verdict.radarAge(now: now.timeIntervalSince1970).map {
                        CoreStrings.t("status.all_arriving_radar", ["minutes": $0])
                    } ?? CoreStrings.t("status.all_arriving"))
                    .accessibilityIdentifier("nativeMap.status.arriving")
                }
            }
        } else if model.stale {
            // No verdict from the backend: the map's own rule found the radar behind.
            Section {
                Text(CoreStrings.t("status.radar_behind")).accessibilityIdentifier("nativeMap.status.behind")
            }
        }
    }

    /// The connection in sentences, when it is not fine.
    private var connectionLines: [String] {
        var lines: [String] = []
        switch monitor.connection {
        case .offline: lines.append(CoreStrings.t("status.connection.offline"))
        case .catchingUp: lines.append(CoreStrings.t("status.connection.catching_up"))
        case .degraded:
            lines += monitor.degradedReasons.map { reason in
                Self.degradedSentences[reason.id].map { CoreStrings.t($0) } ?? reason.reason
            }
        case .online:
            if monitor.slow { lines.append(CoreStrings.t("status.connection.slow")) }
        }
        // Offline says it already: the socket is one of the things that went.
        if model.socketDown, monitor.connection != .offline { lines.append(CoreStrings.t("status.connection.socket")) }
        return lines
    }

    /// The degraded criteria in sentences, by id; one without a sentence of
    /// its own says the diagnostics' words.
    private static let degradedSentences = [
        "api-errors": "status.degraded.api_errors",
        "slow-responses": "status.degraded.slow_responses",
        "stale-publish": "status.degraded.stale_publish",
        "tile-errors": "status.degraded.tile_errors",
    ]

    /// What a component is and where: "Radar, Poland", or "Lightning".
    private func what(_ component: StatusComponent) -> String {
        let kind = CoreStrings.t("status.kind.\(component.kind)")
        guard let domain = component.domain else { return kind }
        return CoreStrings.t("status.where", ["what": kind, "place": place(domain)])
    }

    /// A domain's name in the reader's language, or Europe for the merged composite.
    private func place(_ domain: String) -> String {
        if domain == "eu" { return CoreStrings.t("status.europe") }
        return Locale(identifier: CoreStrings.language).localizedString(forRegionCode: domain.uppercased()) ?? domain.uppercased()
    }

    /// Its state in words, from its newest, in the reader's clock.
    private func state(_ component: StatusComponent) -> String {
        guard let newest = component.newest else { return CoreStrings.t("status.state_none") }
        let time = StatusPill.clock(newest)
        return CoreStrings.t(component.state == .down ? "status.state_down" : "status.state_delayed", ["time": time])
    }
}

extension StatusComponent {
    /// What it is and where, as one key: "radar.pl", "lightning".
    var key: String { domain.map { "\(kind).\($0)" } ?? kind }
}
