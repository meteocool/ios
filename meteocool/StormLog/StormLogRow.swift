//
//  StormLogRow.swift
//  meteocool
//
//  One storm in the storm log's list: its severity as the map colours it and
//  in words, when it came, the place it passed and how close, and what it
//  brought. Drawn in the table's cells through `UIHostingConfiguration`.
//

import SwiftUI

struct StormLogRow: View {
    let passage: StormPassage
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                // At accessibility sizes the time goes below the severity, not beside it.
                let header = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                header {
                    Text(StormLogViewController.severityName(passage.severity))
                        .font(.headline)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Text(StormLogRules.shortWhen(passage))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(Self.placeLine(passage))
                    .font(.subheadline)
                let details = Self.details(passage)
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if passage.endedAt == nil {
                    Label(StormLogViewController.text("storm_log_ongoing", "Still near"), systemImage: "dot.radiowaves.left.and.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // Every row's separator starts under its text, as in Settings.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(passage))
    }

    /// The map's colour behind the storm's symbol: hail's, or a thunderstorm's.
    private var badge: some View {
        let severity = StormLogRules.clamped(passage.severity)
        return RoundedRectangle(cornerRadius: badgeSize * 0.28, style: .continuous)
            .fill(Color(uiColor: StormLogViewController.color(severity)))
            .frame(width: badgeSize, height: badgeSize)
            .overlay {
                Image(systemName: passage.hail ? "cloud.hail.fill" : "cloud.bolt.fill")
                    .font(.body.weight(.semibold))
                    // Black on the moderate storms' yellow, which white would not stand out on.
                    .foregroundStyle(severity == 1 ? Color.black : Color.white)
            }
    }

    /// "Cabin · 6.8 km away": the place, and how close it came.
    static func placeLine(_ passage: StormPassage) -> String {
        let closeness = passage.over
            ? StormLogViewController.text("storm_log_over", "Overhead")
            : String(format: StormLogViewController.text("storm_log_closest", "%@ away"), StormLogRules.kilometres(passage.closestKm))
        return StormLogViewController.where(passage) + " · " + closeness
    }

    /// What it brought, each only when known: echo, top, lightning, hail, how long.
    static func details(_ passage: StormPassage) -> [String] {
        var parts: [String] = []
        if let peak = passage.peakDbz { parts.append(StormLogRules.dbz(peak)) }
        if let top = passage.topKm {
            parts.append(String(format: StormLogViewController.text("storm_log_top", "Top %@"), StormLogRules.top(top)))
        }
        if passage.strikes > 0 {
            parts.append(String(format: StormLogViewController.text("storm_log_strikes", "Lightning: %ld"), passage.strikes))
        }
        if passage.hail { parts.append(NSLocalizedString("native_map_hail", value: "Hail", comment: "")) }
        if let duration = StormLogRules.durationText(passage) { parts.append(duration) }
        return parts
    }

    static func accessibilityLabel(_ passage: StormPassage) -> String {
        var parts = [StormLogViewController.severityName(passage.severity), placeLine(passage), StormLogRules.when(passage)]
        parts += details(passage)
        if passage.endedAt == nil { parts.append(StormLogViewController.text("storm_log_ongoing", "Still near")) }
        return parts.joined(separator: ", ")
    }
}
