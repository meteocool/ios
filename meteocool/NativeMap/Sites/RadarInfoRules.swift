//
//  RadarInfoRules.swift
//  meteocool
//
//  What a reader is told about one radar (core's `lib/radarInfo.ts`, and the
//  files `lib/radarInfoLoad.ts` reads them from): a photo, a few lines on
//  where it stands and what it watches, the facts of the instrument, and
//  where all of that comes from.
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone
//  with RadarSites.swift.
//

import Foundation

/// A radar's photo, published under a free licence; the page loads it from
/// the web map's origin (`public/radars/`).
struct RadarPhoto: Codable, Equatable, Sendable {
    /// The path under the web map's origin: `/radars/<code>.webp`.
    let src: String
    let width: Double
    let height: Double
    /// Whose photo it is, as its page credits it.
    let author: String
    /// The licence's short name: "CC BY-SA 4.0", "Public domain".
    let licence: String
    let licenceUrl: String?
    /// The photo's own page where it was published: Commons, Flickr, Geograph.
    let page: String
}

/// A radar as its country's file keeps it: everything but the text, which
/// is kept by language. A fact nobody could find is nil and left out.
struct RadarFacts: Codable, Equatable, Sendable {
    /// Who runs it: the met service's own short name.
    let `operator`: String?
    /// Its maker and model.
    let system: String?
    /// "C", "S" or "X".
    let band: String?
    let dualPol: Bool?
    /// The year the radar now there went into service, as a reader writes it.
    let since: String?
    let towerM: Double?
    let photo: RadarPhoto?
    /// Where the text and the facts come from, as links; the photo credits its own page.
    let sources: [String]
}

/// A radar's facts with its texts, by language: English and the reader's.
struct RadarInfo: Equatable, Sendable {
    let facts: RadarFacts
    let text: [String: String]
}

enum RadarInfoRules {
    /// Every language core speaks (core's `LOCALES`); the app bundles the
    /// texts of its own ten (scripts/core-radar-info.py).
    static let locales = ["en", "de", "fr", "pl", "nl", "cs", "sk", "lt", "et", "hr", "da", "fi", "sv", "nb"]

    /// Norwegian is written in Bokmål: older systems say "no" for it, and a
    /// reader set to Nynorsk reads Bokmål far more easily than English.
    private static let aliases = ["no": "nb", "nn": "nb"]

    /// "de-AT", "de_DE", "DE" -> "de"; nil for a language core does not have
    /// (core's `normaliseLocale`).
    static func normaliseLocale(_ tag: String?) -> String? {
        let subtag = (tag ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let language = aliases[subtag] ?? subtag
        return locales.contains(language) ? language : nil
    }

    /// The language a reader's texts are in: one core speaks, English otherwise.
    static func textLanguage(_ locale: String?) -> String {
        normaliseLocale(locale) ?? "en"
    }

    /// The description in the reader's language, or in English where there is none in theirs.
    static func infoText(_ info: RadarInfo, _ locale: String?) -> String {
        if let text = info.text[textLanguage(locale)], !text.isEmpty { return text }
        return info.text["en"] ?? ""
    }

    /// The name of the file a radar's facts are in, by its node code.
    static func infoFileOf(_ code: String) -> String {
        "radar-info-\(RadarSites.countryOf(code))"
    }

    /// The name of the file a radar's text in one language is in.
    static func textFileOf(_ code: String, _ language: String) -> String {
        "radar-text-\(language)-\(RadarSites.countryOf(code))"
    }

    /// A radar's facts with its texts, from each language's file that has one.
    static func withTexts(_ code: String, _ facts: RadarFacts, _ texts: [String: [String: String]]) -> RadarInfo {
        var text: [String: String] = [:]
        for (language, file) in texts { if let entry = file[code], !entry.isEmpty { text[language] = entry } }
        return RadarInfo(facts: facts, text: text)
    }

    /// English, which stands in for a text not yet translated, and the reader's language.
    static func languages(for locale: String?) -> [String] {
        let language = textLanguage(locale)
        return language == "en" ? ["en"] : ["en", language]
    }

    /// What there is to say about a radar, in the reader's language, or nil
    /// for one with no entry (core's `loadRadarInfo`). `file` reads one of
    /// the files by name (`radar-info-de`), nil for one there is not.
    static func load(_ code: String, locale: String?, file: (String) -> Data?) -> RadarInfo? {
        let site = RadarSites.siteCode(code)
        guard let data = file(infoFileOf(site)),
              let facts = try? JSONDecoder().decode([String: RadarFacts].self, from: data)[site] else { return nil }
        var texts: [String: [String: String]] = [:]
        for language in languages(for: locale) {
            texts[language] = file(textFileOf(site, language)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        return withTexts(site, facts, texts)
    }

    /// Sources that turn up for many radars, by the name a reader knows them by.
    private static let sourceNames: [(pattern: String, name: String)] = [
        (#"(^|\.)wrd\.mgm\.gov\.tr$"#, "WMO Weather Radar Database"),
        (#"(^|\.)eumetnet\.eu$"#, "EUMETNET OPERA"),
        (#"(^|\.)dwd\.de$"#, "DWD"),
        (#"(^|\.)(ilmatieteenlaitos\.fi|fmi\.fi)$"#, "FMI"),
        (#"(^|\.)(meteoswiss|meteosuisse)\.admin\.ch$"#, "MeteoSwiss"),
        (#"(^|\.)meteofrance\.(com|fr)$"#, "Météo-France"),
        (#"(^|\.)smhi\.se$"#, "SMHI"),
        (#"(^|\.)met\.no$"#, "MET Norway"),
        (#"(^|\.)snl\.no$"#, "Store norske leksikon"),
        (#"(^|\.)meteo\.be$"#, "RMI"),
        (#"(^|\.)knmi\.nl$"#, "KNMI"),
        (#"(^|\.)dmi\.dk$"#, "DMI"),
        (#"(^|\.)met\.ie$"#, "Met Éireann"),
        (#"(^|\.)imgw\.pl$"#, "IMGW"),
        (#"(^|\.)chmi\.cz$"#, "ČHMÚ"),
        (#"(^|\.)meteo\.lt$"#, "LHMT"),
        (#"(^|\.)meteohmd\.hr$"#, "DHMZ"),
        (#"(^|\.)ted\.europa\.eu$"#, "EU tenders (TED)"),
        (#"(^|\.)wikidata\.org$"#, "Wikidata"),
        (#"(^|\.)commons\.wikimedia\.org$"#, "Wikimedia Commons"),
        (#"(^|\.)flickr\.com$"#, "Flickr"),
        (#"(^|\.)geo\.hlipp\.de$"#, "Geograph Deutschland"),
    ]

    /// What a source link says: the name of whoever published it where it is
    /// a known one ("DWD", "Wikipedia (de)"), its site's address otherwise.
    /// Two links to the same publisher are told apart by a number.
    static func sourceLabels(_ urls: [String]) -> [String] {
        let names = urls.map { url -> String in
            guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return url }
            if host.range(of: #"^[a-z-]+\.(wikipedia|wikiversity)\.org$"#, options: .regularExpression) != nil {
                let parts = host.split(separator: ".")
                return "\(parts[1] == "wikipedia" ? "Wikipedia" : "Wikiversity") (\(parts[0]))"
            }
            if let known = sourceNames.first(where: { host.range(of: $0.pattern, options: .regularExpression) != nil }) {
                return known.name
            }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        var total: [String: Int] = [:]
        for name in names { total[name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return names.map { name in
            guard total[name, default: 0] >= 2 else { return name }
            seen[name, default: 0] += 1
            return "\(name) \(seen[name]!)"
        }
    }

    /// A source as the page lists it: where it is, what it says.
    struct Source: Equatable {
        let url: String
        let label: String
    }

    /// The text's and facts' sources, then where the photo was published,
    /// unless that is one of them (core's `sourcesOf`). `photoSource` words
    /// the photo's: "Photo (Wikimedia Commons)".
    static func sources(_ urls: [String], photoPage: String?, photoSource: (String) -> String) -> [Source] {
        var listed = zip(urls, sourceLabels(urls)).map { Source(url: $0.0, label: $0.1) }
        if let photoPage, !urls.contains(photoPage) {
            listed.append(Source(url: photoPage, label: photoSource(sourceLabels([photoPage])[0])))
        }
        return listed
    }

    /// A fact as the page lists it: what it is, and its value.
    struct Fact: Equatable {
        let label: String
        let value: String
    }

    /// The instrument's facts, in the reader's words (core's `factsOf`): the
    /// entry's, then the antenna's height and the reach from the network
    /// tables (`site`). A fact nobody found is left out. `tr` is core's `$_`.
    static func facts(_ facts: RadarFacts?, site: RadarSite?, language: String,
                      tr: (String, [String: String]) -> String) -> [Fact] {
        var out: [Fact] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { out.append(Fact(label: tr(label, [:]), value: value)) }
        }
        add("site.info.operator", facts?.operator)
        add("site.info.system", facts?.system)
        if let facts, facts.band?.isEmpty == false || facts.dualPol != nil {
            let parts = [
                facts.band.flatMap { $0.isEmpty ? nil : tr("site.info.band_value", ["band": $0]) },
                facts.dualPol.map { tr($0 ? "site.info.dual_pol" : "site.info.single_pol", [:]) },
            ].compactMap { $0 }
            add("site.info.band", parts.joined(separator: " · "))
        }
        add("site.info.since", facts?.since)
        if let site { add("site.info.antenna", tr("site.info.antenna_value", ["height": number(site.heightM, language)])) }
        if let tower = facts?.towerM, tower != 0 { add("site.info.tower", tr("site.info.metres", ["value": number(tower, language)])) }
        if let site, site.rangeKm != 0 { add("site.info.range", tr("site.info.km", ["value": number(site.rangeKm, language)])) }
        return out
    }

    /// A number as the reader's language writes it, to `digits` places at
    /// most (core's `toLocaleString(language, { maximumFractionDigits })`).
    static func number(_ value: Double, _ language: String, digits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
