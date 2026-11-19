import Foundation

/// Checks each radar's page (core's `radarInfo.test.ts`, test for test): in
/// which language a reader reads it, which file holds what, how sources are
/// named, and that the bundled files (scripts/core-radar-info.py, the path
/// given) describe every radar there is. Also the page's own facts and
/// sources (`RadarInfo.svelte`'s `factsOf` and `sourcesOf`).
@main
struct RadarInfoCheck {
    static let languages = ["en", "de", "da", "et", "fi", "hr", "lt", "nb", "nl", "sv"]

    static func entry(_ text: [String: String]) -> RadarInfo {
        RadarInfo(facts: RadarFacts(operator: nil, system: nil, band: nil, dualPol: nil, since: nil, towerM: nil, photo: nil, sources: []),
                  text: text)
    }

    static func main() {
        guard CommandLine.arguments.count > 1 else { fatalError("usage: check-radar-info meteocool/NativeMap/RadarInfo") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        rules()
        files(directory)
        page()
        print("Radar page checks passed")
    }

    static func rules() {
        // a German reader reads the German text, whichever region their German is from
        let german = entry(["en": "On a hill.", "de": "Auf einem Hügel."])
        precondition(RadarInfoRules.infoText(german, "de") == "Auf einem Hügel.")
        precondition(RadarInfoRules.infoText(german, "de-AT") == "Auf einem Hügel.")

        // a reader in a language the app does not speak reads the English text
        precondition(RadarInfoRules.infoText(german, "en") == "On a hill.")
        precondition(RadarInfoRules.infoText(german, "pt-BR") == "On a hill.")
        precondition(RadarInfoRules.infoText(german, nil) == "On a hill.")

        // a text not yet translated reads in English
        precondition(RadarInfoRules.infoText(entry(["en": "On a hill."]), "pl") == "On a hill.")

        // a Norwegian reader on an older system reads Bokmål
        precondition(RadarInfoRules.textLanguage("no") == "nb")
        precondition(RadarInfoRules.textLanguage("nn-NO") == "nb")

        // a radar's text in a language is in that language's file for its country
        precondition(RadarInfoRules.textFileOf("deisn", "fr") == "radar-text-fr-de")
        precondition(RadarInfoRules.textFileOf("isn", "en") == "radar-text-en-de")

        // a radar takes its text from each language's file that has one
        let facts = RadarFacts(operator: "DWD", system: nil, band: nil, dualPol: nil, since: nil, towerM: nil, photo: nil, sources: [])
        let info = RadarInfoRules.withTexts("deisn", facts, ["en": ["deisn": "On a hill."], "fr": ["deoft": "Sur une colline."]])
        precondition(info.text == ["en": "On a hill."])
        precondition(info.facts.operator == "DWD")

        // a radar's texts are in its country's file
        precondition(RadarInfoRules.infoFileOf("deisn") == "radar-info-de")
        precondition(RadarInfoRules.infoFileOf("frnan") == "radar-info-fr")
        // DWD's bare three letters, from volumes older than the other networks.
        precondition(RadarInfoRules.infoFileOf("isn") == "radar-info-de")

        // a source is named by who published it, where it is a known publisher
        precondition(RadarInfoRules.sourceLabels([
            "https://www.dwd.de/DE/derdwd/messnetz/atmosphaerenbeobachtung/_functions/HaeufigGesucht/radarverbund.html",
            "https://de.wikipedia.org/wiki/Wetterradar",
            "https://wrd.mgm.gov.tr/Home/Detail?id=1",
            "https://www.schwaebische.de/a/radar",
        ]) == ["DWD", "Wikipedia (de)", "WMO Weather Radar Database", "schwaebische.de"])

        // two sources from the same publisher are told apart
        precondition(RadarInfoRules.sourceLabels(["https://www.smhi.se/a", "https://www.smhi.se/b", "https://www.met.no/c"])
            == ["SMHI 1", "SMHI 2", "MET Norway"])
    }

    static func files(_ directory: URL) {
        func read<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            let folder = name.hasPrefix("radar-text-") ? directory.appendingPathComponent("text") : directory
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(name).json")) else { return nil }
            return try! JSONDecoder().decode(T.self, from: data)
        }
        let names = { (folder: URL) in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        }
        let infoFiles = Dictionary(uniqueKeysWithValues: names(directory).map { ($0, read($0, [String: RadarFacts].self)!) })
        let textFiles = Dictionary(uniqueKeysWithValues: names(directory.appendingPathComponent("text")).map { ($0, read($0, [String: String].self)!) })
        precondition(!infoFiles.isEmpty && !textFiles.isEmpty, "no radar files in \(directory.path)")

        // every radar there is has an entry, in its country's file
        for code in RadarSites.all.keys {
            precondition(infoFiles[RadarInfoRules.infoFileOf(code)]?[code] != nil, "\(code) has no entry in \(RadarInfoRules.infoFileOf(code)).json")
        }

        // every entry is a radar there is, in its own country's file
        for (file, radars) in infoFiles {
            for code in radars.keys {
                precondition(RadarSites.all[code] != nil, "\(file).json describes \(code), which is no radar")
                precondition(RadarInfoRules.infoFileOf(code) == file, "\(code) is in \(file).json")
            }
        }

        // every radar has a text of a few sentences in every language the app speaks
        for language in languages {
            for code in RadarSites.all.keys {
                let text = textFiles[RadarInfoRules.textFileOf(code, language)]?[code] ?? ""
                precondition(text.count >= 60, "\(code)'s \(language) text is missing or too short")
                precondition(text.count <= 600, "\(code)'s \(language) text runs to \(text.count) characters")
            }
        }

        // every text file holds only its own country's radars
        for (file, radars) in textFiles {
            let language = String(file.split(separator: "-")[2])
            for code in radars.keys { precondition(RadarInfoRules.textFileOf(code, language) == file, "\(code) is in \(file).json") }
        }

        // every photo says whose it is and under which licence (core also
        // checks the picture is in its repository: the app loads it from there)
        for radars in infoFiles.values {
            for (code, info) in radars {
                guard let photo = info.photo else { continue }
                precondition(photo.src == "/radars/\(code).webp", "\(code)'s photo is \(photo.src)")
                precondition(!photo.author.trimmingCharacters(in: .whitespaces).isEmpty
                             && !photo.licence.trimmingCharacters(in: .whitespaces).isEmpty, "\(code)'s photo names no author or licence")
                precondition(photo.page.hasPrefix("https://"), "\(code)'s photo links to no page of its own")
                precondition(photo.width > 0 && photo.height > 0)
            }
        }

        // every radar names where its text and facts come from
        for radars in infoFiles.values {
            for (code, info) in radars {
                precondition(!info.sources.isEmpty, "\(code) names no source")
                for url in info.sources {
                    precondition(url.range(of: #"^https?://[^/]+\.[a-z]+"#, options: .regularExpression) != nil, "\(code): \(url)")
                }
            }
        }

        // The app's own loading: a German reader of a DWD radar, an old DWD
        // code, a Norwegian reader on an older system, and a radar there is not.
        let file = { (name: String) -> Data? in
            let folder = name.hasPrefix("radar-text-") ? directory.appendingPathComponent("text") : directory
            return try? Data(contentsOf: folder.appendingPathComponent("\(name).json"))
        }
        let isen = RadarInfoRules.load("deisn", locale: "de-AT", file: file)
        precondition(isen?.text.keys.sorted() == ["de", "en"])
        precondition(RadarInfoRules.load("ISN", locale: "en", file: file)?.text.keys.sorted() == ["en"])
        precondition(RadarInfoRules.load("nosta", locale: "no", file: file)?.text["nb"] != nil)
        precondition(RadarInfoRules.load("xxabc", locale: "en", file: file) == nil)
    }

    static func page() {
        let tr = { (key: String, values: [String: String]) -> String in
            values.sorted { $0.key < $1.key }.reduce(key) { "\($0) \($1.key)=\($1.value)" }
        }
        let site = RadarSite(name: "Isen", lat: 48.17, lon: 12.1, heightM: 677.8, lowestDeg: 0.5, rangeKm: 1180)

        // Numbers as the reader's language writes them, whole by default.
        precondition(RadarInfoRules.number(677.8, "en") == "678")
        precondition(RadarInfoRules.number(1180, "en") == "1,180")
        precondition(RadarInfoRules.number(1180, "de") == "1.180")
        precondition(RadarInfoRules.number(12.25, "en", digits: 1) == "12.3")

        let full = RadarFacts(operator: "DWD", system: "Gematronik", band: "C", dualPol: true, since: "2012", towerM: 30,
                              photo: nil, sources: [])
        precondition(RadarInfoRules.facts(full, site: site, language: "de", tr: tr) == [
            .init(label: "site.info.operator", value: "DWD"),
            .init(label: "site.info.system", value: "Gematronik"),
            .init(label: "site.info.band", value: "site.info.band_value band=C · site.info.dual_pol"),
            .init(label: "site.info.since", value: "2012"),
            .init(label: "site.info.antenna", value: "site.info.antenna_value height=678"),
            .init(label: "site.info.tower", value: "site.info.metres value=30"),
            .init(label: "site.info.range", value: "site.info.km value=1.180"),
        ])
        // A fact nobody found is left out; single polarisation is a fact.
        let sparse = RadarFacts(operator: nil, system: nil, band: nil, dualPol: false, since: nil, towerM: nil, photo: nil, sources: [])
        precondition(RadarInfoRules.facts(sparse, site: nil, language: "en", tr: tr) == [
            .init(label: "site.info.band", value: "site.info.single_pol"),
        ])
        precondition(RadarInfoRules.facts(nil, site: nil, language: "en", tr: tr).isEmpty)

        // The photo's page ends the sources, unless it is one of them.
        let photoSource = { (source: String) in "Photo (\(source))" }
        precondition(RadarInfoRules.sources(["https://www.dwd.de/a"], photoPage: "https://commons.wikimedia.org/wiki/File:X.jpg",
                                            photoSource: photoSource).map(\.label) == ["DWD", "Photo (Wikimedia Commons)"])
        precondition(RadarInfoRules.sources(["https://www.flickr.com/p"], photoPage: "https://www.flickr.com/p",
                                            photoSource: photoSource).map(\.label) == ["Flickr"])
        precondition(RadarInfoRules.sources(["https://www.dwd.de/a"], photoPage: nil, photoSource: photoSource).map(\.label) == ["DWD"])
    }
}
