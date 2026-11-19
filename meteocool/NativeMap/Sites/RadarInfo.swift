//
//  RadarInfo.swift
//  meteocool
//
//  A page for each radar (core's `RadarInfo.svelte`), opened from the "i"
//  in the open radar's tray: its photo, where it stands and what it
//  watches, the facts of the instrument, where all of that comes from, and
//  the way on to "How the Radar Works".
//

import SwiftUI

/// One radar, for the reader who asks what it is. The facts and texts are
/// the app's own copy of core's (scripts/core-radar-info.py); the photo is
/// fetched from the web map's origin only once this is open, with the
/// system's caching, and holds its place while it comes so the text under
/// it does not jump. A photo that will not load is left out quietly, with
/// its source. The facts stand beside the photo where the sheet is wide.
struct RadarInfoPage: View {
    let code: String
    let info: RadarInfo?
    /// The web map's origin, which serves the photos (`public/radars/`).
    let photoOrigin: URL
    let close: () -> Void
    let explain: () -> Void

    @State private var photoFailed = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// No taller than this: the width follows from the photo's proportions,
    /// so the facts and the text are not a scroll away.
    private static let photoMaxHeight: CGFloat = 340

    private var site: RadarSite? { RadarSites.site(code) }
    private var name: String { site?.name ?? code.uppercased() }
    private var language: String { CoreStrings.language }
    private var photo: RadarPhoto? { photoFailed ? nil : info?.facts.photo }

    private var facts: [RadarInfoRules.Fact] {
        RadarInfoRules.facts(info?.facts, site: site, language: language) { key, values in CoreStrings.t(key, values) }
    }

    private var sources: [RadarInfoRules.Source] {
        RadarInfoRules.sources(info?.facts.sources ?? [], photoPage: photo?.page) { source in
            CoreStrings.t("site.info.photo_source", ["source": source])
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    top
                    if let info, case let text = RadarInfoRules.infoText(info, language), !text.isEmpty {
                        Text(text)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("nativeMap.radarInfo.text")
                    } else {
                        Text(CoreStrings.t("site.info.none"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("nativeMap.radarInfo.text")
                    }
                    if !sources.isEmpty { sourceList }
                    explainRow
                }
                .padding()
            }
            .navigationTitle(CoreStrings.t("site.title", ["name": name]))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .accessibilityLabel(CoreStrings.t("close"))
                        .accessibilityIdentifier("nativeMap.radarInfo.close")
                }
            }
        }
        .accessibilityIdentifier("nativeMap.radarInfo")
    }

    /// The photo and the facts: side by side where the sheet is wide and the
    /// text is not at an accessibility size, stacked otherwise.
    @ViewBuilder
    private var top: some View {
        if let photo, sizeClass == .regular, !typeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 20) {
                figure(photo).frame(maxWidth: .infinity)
                factList.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if let photo { figure(photo) }
                factList
            }
        }
    }

    private func figure(_ photo: RadarPhoto) -> some View {
        let ratio = photo.width / photo.height
        return VStack(spacing: 6) {
            AsyncImage(url: URL(string: photo.src, relativeTo: photoOrigin)?.absoluteURL,
                       transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.2))) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Color.clear.onAppear { photoFailed = true }
                default:
                    ZStack {
                        Rectangle().fill(.fill.tertiary)
                        ProgressView()
                    }
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: Self.photoMaxHeight * ratio)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel(CoreStrings.t("site.info.photo_alt", ["name": name]))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("nativeMap.radarInfo.photo")
            Text(credit(photo))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("nativeMap.radarInfo.credit")
        }
        .frame(maxWidth: .infinity)
    }

    /// "Photo: <author>" linked to where it was published, then its licence,
    /// linked to the licence where it has a page, as the licences ask.
    private func credit(_ photo: RadarPhoto) -> AttributedString {
        var author = AttributedString(CoreStrings.t("site.info.photo_credit", ["author": photo.author]))
        author.link = URL(string: photo.page)
        var licence = AttributedString(photo.licence)
        licence.link = photo.licenceUrl.flatMap(URL.init(string:))
        return author + AttributedString(", ") + licence
    }

    @ViewBuilder
    private var factList: some View {
        if !facts.isEmpty {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(facts, id: \.label) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label).foregroundStyle(.secondary)
                            Text(fact.value)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.body)
                .accessibilityIdentifier("nativeMap.radarInfo.facts")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(facts, id: \.label) { fact in
                        GridRow {
                            Text(fact.label).foregroundStyle(.secondary)
                            Text(fact.value).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.body)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nativeMap.radarInfo.facts")
            }
        }
    }

    /// The sources the text and facts were taken from, each named by its
    /// publisher and linked, then where the photo was published.
    private var sourceList: some View {
        var links = AttributedString()
        for (index, source) in sources.enumerated() {
            if index > 0 { links += AttributedString("  ·  ") }
            var label = AttributedString(source.label)
            label.link = URL(string: source.url)
            links += label
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(CoreStrings.t("site.info.sources"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(links)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.radarInfo.sources")
    }

    /// The way on to what every radar does: a row of its own, like the rows
    /// of Settings, so it reads as a place to go.
    private var explainRow: some View {
        Button(action: explain) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CoreStrings.t("site.info.how")).font(.body.weight(.semibold))
                    Text(CoreStrings.t("site.info.how_sub")).font(.footnote).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(CoreStrings.t("site.info.how"))
        .accessibilityHint(CoreStrings.t("site.info.how_sub"))
        .accessibilityIdentifier("nativeMap.radarInfo.explain")
    }
}

/// The app's copy of core's radar files, read from the bundle.
enum RadarInfoBundle {
    static func load(_ code: String, locale: String) -> RadarInfo? {
        RadarInfoRules.load(code, locale: locale) { name in
            Bundle.main.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        }
    }
}
