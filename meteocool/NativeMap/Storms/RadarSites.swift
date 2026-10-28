//
//  RadarSites.swift
//  meteocool
//
//  The weather radars of every network (core's `lib/radarSites.ts`, generated
//  from it): which radars a storm's volume was built from, how far each
//  stood and how high its lowest beam passed over the storm.
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import Foundation

struct RadarSite: Equatable, Sendable {
    let name: String
    let lat: Double
    let lon: Double
    /// Antenna height above sea level, in metres.
    let heightM: Double
    /// The lowest tilt its network scans, degrees.
    let lowestDeg: Double
    /// How far that tilt reaches, in kilometres.
    let rangeKm: Double
}

enum RadarSites {
    static let all: [String: RadarSite] = [
        "deasb": RadarSite(name: "Borkum", lat: 53.564129, lon: 6.748317, heightM: 36.2, lowestDeg: 0.5, rangeKm: 180.0),
        "deboo": RadarSite(name: "Boostedt", lat: 54.004381, lon: 10.046899, heightM: 124.6, lowestDeg: 0.5, rangeKm: 180.0),
        "dedrs": RadarSite(name: "Dresden", lat: 51.124639, lon: 13.768639, heightM: 263.4, lowestDeg: 0.5, rangeKm: 180.0),
        "deeis": RadarSite(name: "Eisberg", lat: 49.540667, lon: 12.402788, heightM: 799.1, lowestDeg: 0.5, rangeKm: 180.0),
        "deess": RadarSite(name: "Essen", lat: 51.405649, lon: 6.967111, heightM: 185.1, lowestDeg: 0.5, rangeKm: 180.0),
        "defbg": RadarSite(name: "Feldberg", lat: 47.873611, lon: 8.003611, heightM: 1516.1, lowestDeg: 0.5, rangeKm: 180.0),
        "defld": RadarSite(name: "Flechtdorf", lat: 51.311197, lon: 8.801998, heightM: 627.9, lowestDeg: 0.5, rangeKm: 180.0),
        "dehnr": RadarSite(name: "Hannover", lat: 52.460083, lon: 9.694533, heightM: 97.8, lowestDeg: 0.5, rangeKm: 180.0),
        "deisn": RadarSite(name: "Isen", lat: 48.174705, lon: 12.101779, heightM: 677.8, lowestDeg: 0.5, rangeKm: 180.0),
        "demem": RadarSite(name: "Memmingen", lat: 48.042145, lon: 10.219222, heightM: 724.4, lowestDeg: 0.5, rangeKm: 180.0),
        "deneu": RadarSite(name: "Neuhaus", lat: 50.500114, lon: 11.135034, heightM: 879.6, lowestDeg: 0.5, rangeKm: 180.0),
        "denhb": RadarSite(name: "Neuheilenbach", lat: 50.109656, lon: 6.548328, heightM: 585.9, lowestDeg: 0.5, rangeKm: 180.0),
        "deoft": RadarSite(name: "Offenthal", lat: 49.984745, lon: 8.712933, heightM: 245.8, lowestDeg: 0.5, rangeKm: 180.0),
        "depro": RadarSite(name: "Prötzel", lat: 52.648667, lon: 13.858212, heightM: 193.9, lowestDeg: 0.5, rangeKm: 180.0),
        "deros": RadarSite(name: "Rostock", lat: 54.17566, lon: 12.058076, heightM: 37.0, lowestDeg: 0.5, rangeKm: 180.0),
        "detur": RadarSite(name: "Türkheim", lat: 48.585379, lon: 9.782675, heightM: 767.6, lowestDeg: 0.5, rangeKm: 180.0),
        "deumd": RadarSite(name: "Ummendorf", lat: 52.160096, lon: 11.176091, heightM: 185.2, lowestDeg: 0.5, rangeKm: 180.0),
        "chalb": RadarSite(name: "Albis", lat: 47.284332, lon: 8.512, heightM: 938.0, lowestDeg: -0.2, rangeKm: 246.0),
        "chdol": RadarSite(name: "La Dôle", lat: 46.425113, lon: 6.099415, heightM: 1682.0, lowestDeg: -0.2, rangeKm: 246.0),
        "chlem": RadarSite(name: "Monte Lema", lat: 46.040761, lon: 8.833217, heightM: 1626.0, lowestDeg: -0.2, rangeKm: 246.0),
        "chppm": RadarSite(name: "Plaine Morte", lat: 46.370646, lon: 7.486552, heightM: 2937.0, lowestDeg: -0.2, rangeKm: 246.0),
        "chwei": RadarSite(name: "Weissfluhgipfel", lat: 46.834974, lon: 9.794458, heightM: 2850.0, lowestDeg: -0.2, rangeKm: 246.0),
        "frabb": RadarSite(name: "Abbeville", lat: 50.13595, lon: 1.8347, heightM: 83.6, lowestDeg: 0.4, rangeKm: 256.32),
        "fraja": RadarSite(name: "Ajaccio", lat: 41.95313, lon: 8.70054, heightM: 784.0, lowestDeg: 0.4, rangeKm: 256.32),
        "frale": RadarSite(name: "Aléria", lat: 42.12971, lon: 9.49639, heightM: 63.0, lowestDeg: 0.4, rangeKm: 256.32),
        "frave": RadarSite(name: "Avesnes", lat: 50.12832, lon: 3.81181, heightM: 208.8, lowestDeg: 0.4, rangeKm: 256.32),
        "frbla": RadarSite(name: "Blaisy-Haut", lat: 47.35515, lon: 4.77594, heightM: 607.2, lowestDeg: 0.4, rangeKm: 256.32),
        "frbol": RadarSite(name: "Bollène", lat: 44.32305, lon: 4.76221, heightM: 325.0, lowestDeg: 0.4, rangeKm: 256.32),
        "frbor": RadarSite(name: "Bordeaux", lat: 44.83147, lon: -0.69188, heightM: 70.0, lowestDeg: 0.4, rangeKm: 256.32),
        "frbou": RadarSite(name: "Bourges", lat: 47.05861, lon: 2.35955, heightM: 173.5, lowestDeg: 0.4, rangeKm: 256.32),
        "frcae": RadarSite(name: "Falaise", lat: 48.92716, lon: -0.14955, heightM: 167.4, lowestDeg: 0.4, rangeKm: 256.32),
        "frcol": RadarSite(name: "Collobrières", lat: 43.21656, lon: 6.37291, heightM: 653.7, lowestDeg: 0.4, rangeKm: 256.32),
        "frgre": RadarSite(name: "Grèzes", lat: 45.1044, lon: 1.36967, heightM: 360.3, lowestDeg: 0.4, rangeKm: 256.32),
        "frlep": RadarSite(name: "Sembadel", lat: 45.28922, lon: 3.70948, heightM: 1143.4, lowestDeg: 0.4, rangeKm: 256.32),
        "frmcl": RadarSite(name: "Montclar", lat: 43.9905, lon: 2.60962, heightM: 678.7, lowestDeg: 0.4, rangeKm: 256.32),
        "frmom": RadarSite(name: "Momuy", lat: 43.62447, lon: -0.6094, heightM: 145.7, lowestDeg: 0.4, rangeKm: 256.32),
        "frmtc": RadarSite(name: "Montancy", lat: 47.36861, lon: 7.01897, heightM: 925.7, lowestDeg: 0.4, rangeKm: 256.32),
        "frnan": RadarSite(name: "Nancy", lat: 48.71576, lon: 6.58156, heightM: 296.3, lowestDeg: 0.4, rangeKm: 256.32),
        "frnim": RadarSite(name: "Nîmes", lat: 43.80614, lon: 4.50269, heightM: 78.1, lowestDeg: 0.4, rangeKm: 256.32),
        "frniz": RadarSite(name: "Saint-Nizier", lat: 46.06781, lon: 4.44535, heightM: 919.8, lowestDeg: 0.4, rangeKm: 256.32),
        "fropo": RadarSite(name: "Opoul", lat: 42.91839, lon: 2.86499, heightM: 718.0, lowestDeg: 0.4, rangeKm: 256.32),
        "frpla": RadarSite(name: "Plabennec", lat: 48.46088, lon: -4.42983, heightM: 110.8, lowestDeg: 0.4, rangeKm: 256.32),
        "frtou": RadarSite(name: "Toulouse", lat: 43.57432, lon: 1.3763, heightM: 187.1, lowestDeg: 0.4, rangeKm: 256.32),
        "frtra": RadarSite(name: "Trappes", lat: 48.77457, lon: 2.00831, heightM: 190.2, lowestDeg: 0.4, rangeKm: 256.32),
        "frtre": RadarSite(name: "Treillières", lat: 47.33741, lon: -1.65632, heightM: 81.0, lowestDeg: 0.4, rangeKm: 256.32),
        "frtro": RadarSite(name: "Arcis-sur-Aube", lat: 48.46213, lon: 4.30932, heightM: 164.8, lowestDeg: 0.4, rangeKm: 256.32),
        "czbrd": RadarSite(name: "Brdy", lat: 49.6583, lon: 13.8178, heightM: 916.0, lowestDeg: 0.1, rangeKm: 260.0),
        "czska": RadarSite(name: "Skalky", lat: 49.5011, lon: 16.7885, heightM: 767.0, lowestDeg: 0.1, rangeKm: 260.0),
        "plbrz": RadarSite(name: "Brzuchania", lat: 50.394169, lon: 20.083228, heightM: 434.4, lowestDeg: 0.5, rangeKm: 250.0),
        "plgdy": RadarSite(name: "Gdynia", lat: 54.5009, lon: 18.2718, heightM: 261.0, lowestDeg: 0.5, rangeKm: 250.0),
        "plgsa": RadarSite(name: "Góra Świętej Anny", lat: 50.4639, lon: 18.1532, heightM: 433.0, lowestDeg: 0.5, rangeKm: 250.0),
        "plleg": RadarSite(name: "Legionowo", lat: 52.4052, lon: 20.9611, heightM: 122.3, lowestDeg: 0.5, rangeKm: 250.0),
        "plpas": RadarSite(name: "Pastewnik", lat: 50.8925, lon: 16.0395, heightM: 691.9, lowestDeg: 0.5, rangeKm: 250.0),
        "plpoz": RadarSite(name: "Poznań", lat: 52.4133, lon: 16.797, heightM: 123.3, lowestDeg: 0.5, rangeKm: 250.0),
        "plram": RadarSite(name: "Ramża", lat: 50.1513, lon: 18.7251, heightM: 357.1, lowestDeg: 0.5, rangeKm: 250.0),
        "plrze": RadarSite(name: "Rzeszów", lat: 50.1141, lon: 22.037, heightM: 241.2, lowestDeg: 0.5, rangeKm: 250.0),
        "plswi": RadarSite(name: "Świdwin", lat: 53.7958, lon: 15.8368, heightM: 146.6, lowestDeg: 0.5, rangeKm: 250.0),
        "pluzr": RadarSite(name: "Użranki", lat: 53.8557, lon: 21.4123, heightM: 237.0, lowestDeg: 0.5, rangeKm: 250.0),
        "behel": RadarSite(name: "Helchteren", lat: 51.0702, lon: 5.4054, heightM: 144.0, lowestDeg: 0.3, rangeKm: 200.0),
        "bejab": RadarSite(name: "Jabbeke", lat: 51.1917, lon: 3.0642, heightM: 50.0, lowestDeg: 0.3, rangeKm: 250.0),
        "bewid": RadarSite(name: "Wideumont", lat: 49.9136, lon: 5.5044, heightM: 585.0, lowestDeg: 0.3, rangeKm: 250.0),
        "skjav": RadarSite(name: "Malý Javorník", lat: 48.255636, lon: 17.152379, heightM: 600.0, lowestDeg: 0.0, rangeKm: 240.0),
        "skkoj": RadarSite(name: "Kojšovská hoľa", lat: 48.782727, lon: 20.987328, heightM: 1256.0, lowestDeg: 0.0, rangeKm: 240.0),
        "skkub": RadarSite(name: "Kubínska hoľa", lat: 49.27167, lon: 19.24935, heightM: 1425.0, lowestDeg: 0.0, rangeKm: 240.0),
        "sklaz": RadarSite(name: "Španí laz", lat: 48.240409, lon: 19.25732, heightM: 661.0, lowestDeg: 0.0, rangeKm: 240.0),
        "ltlau": RadarSite(name: "Laukuva", lat: 55.60904, lon: 22.2395, heightM: 200.0, lowestDeg: 0.5, rangeKm: 249.3),
        "ltvil": RadarSite(name: "Vilnius (Trakų Vokė)", lat: 54.62622, lon: 25.10678, heightM: 193.0, lowestDeg: 0.5, rangeKm: 249.3),
        "eehar": RadarSite(name: "Harku", lat: 59.397076, lon: 24.60213, heightM: 70.0, lowestDeg: 0.5, rangeKm: 249.9),
        "eesur": RadarSite(name: "Sürgavere", lat: 58.48231, lon: 25.51866, heightM: 157.0, lowestDeg: 0.5, rangeKm: 249.9),
        "iedub": RadarSite(name: "Dublin", lat: 53.4299, lon: -6.2443, heightM: 99.0, lowestDeg: 0.5, rangeKm: 250.0),
        "iesha": RadarSite(name: "Shannon", lat: 52.692787, lon: -8.919994, heightM: 29.0, lowestDeg: 0.5, rangeKm: 248.5),
        "hrbil": RadarSite(name: "Bilogora", lat: 45.883527, lon: 17.20046, heightM: 280.0, lowestDeg: 0.5, rangeKm: 249.8),
        "hrdeb": RadarSite(name: "Debeljak", lat: 44.04516, lon: 15.37637, heightM: 208.0, lowestDeg: 0.5, rangeKm: 249.8),
        "hrgol": RadarSite(name: "Goli", lat: 45.020477, lon: 14.122337, heightM: 553.0, lowestDeg: 0.5, rangeKm: 249.8),
        "hrgra": RadarSite(name: "Gradište", lat: 45.15917, lon: 18.70333, heightM: 110.0, lowestDeg: 0.5, rangeKm: 249.8),
        "hrulj": RadarSite(name: "Uljenje", lat: 42.89439, lon: 17.47829, heightM: 463.0, lowestDeg: 0.5, rangeKm: 249.8),
        "dkbor": RadarSite(name: "Bornholm", lat: 55.11275, lon: 14.887517, heightM: 171.0, lowestDeg: 0.5, rangeKm: 238.0),
        "dkrom": RadarSite(name: "Rømø", lat: 55.173111, lon: 8.552, heightM: 15.0, lowestDeg: 0.5, rangeKm: 238.0),
        "dksam": RadarSite(name: "Samsø", lat: 55.8119, lon: 10.5853, heightM: 48.0, lowestDeg: 0.5, rangeKm: 238.0),
        "dksin": RadarSite(name: "Sindal", lat: 57.489306, lon: 10.136472, heightM: 109.0, lowestDeg: 0.5, rangeKm: 238.0),
        "dkste": RadarSite(name: "Stevns", lat: 55.326194, lon: 12.449278, heightM: 53.0, lowestDeg: 0.5, rangeKm: 238.0),
        "nldhl": RadarSite(name: "Den Helder", lat: 52.95279, lon: 4.79061, heightM: 55.0, lowestDeg: 0.3, rangeKm: 250.0),
        "nlhrw": RadarSite(name: "Herwijnen", lat: 51.8369, lon: 5.1381, heightM: 25.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fianj": RadarSite(name: "Anjalankoski", lat: 60.90387, lon: 27.10806, heightM: 139.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fikan": RadarSite(name: "Kankaanpää", lat: 61.81081, lon: 22.50203, heightM: 175.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fikau": RadarSite(name: "Kaunispää", lat: 68.43443, lon: 27.44399, heightM: 463.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fikes": RadarSite(name: "Kesälahti", lat: 61.906992, lon: 29.79772, heightM: 174.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fikor": RadarSite(name: "Korpo", lat: 60.12847, lon: 21.64338, heightM: 61.0, lowestDeg: 0.5, rangeKm: 250.0),
        "fikuo": RadarSite(name: "Kuopio", lat: 62.8626, lon: 27.38147, heightM: 268.0, lowestDeg: 0.3, rangeKm: 250.0),
        "filuo": RadarSite(name: "Luosto", lat: 67.1391, lon: 26.896916, heightM: 533.0, lowestDeg: 0.1, rangeKm: 250.0),
        "finur": RadarSite(name: "Nurmes", lat: 63.83786, lon: 29.44893, heightM: 323.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fipet": RadarSite(name: "Petäjävesi", lat: 62.30452, lon: 25.44009, heightM: 271.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fiuta": RadarSite(name: "Utajärvi", lat: 64.77493, lon: 26.31888, heightM: 118.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fivih": RadarSite(name: "Vihti", lat: 60.55619, lon: 24.495592, heightM: 181.0, lowestDeg: 0.3, rangeKm: 250.0),
        "fivim": RadarSite(name: "Vimpeli", lat: 63.10484, lon: 23.82086, heightM: 200.0, lowestDeg: 0.3, rangeKm: 250.0),
        "seang": RadarSite(name: "Ängelholm", lat: 56.367451, lon: 12.851691, heightM: 209.0, lowestDeg: 0.5, rangeKm: 240.0),
        "seatv": RadarSite(name: "Åtvidaberg (Vilebo)", lat: 58.105907, lon: 15.936496, heightM: 222.0, lowestDeg: 0.5, rangeKm: 240.0),
        "sebaa": RadarSite(name: "Bålsta", lat: 59.611019, lon: 17.583338, heightM: 83.0, lowestDeg: 0.5, rangeKm: 240.0),
        "sehuv": RadarSite(name: "Hudiksvall", lat: 61.57711, lon: 16.714434, heightM: 389.0, lowestDeg: 0.5, rangeKm: 240.0),
        "sekaa": RadarSite(name: "Karlskrona", lat: 56.295544, lon: 15.610225, heightM: 132.0, lowestDeg: 0.5, rangeKm: 240.0),
        "sekrn": RadarSite(name: "Kiruna", lat: 67.708755, lon: 20.61779, heightM: 647.0, lowestDeg: 0.5, rangeKm: 240.0),
        "selek": RadarSite(name: "Leksand", lat: 60.723042, lon: 14.877571, heightM: 457.0, lowestDeg: 0.5, rangeKm: 240.0),
        "sella": RadarSite(name: "Luleå (Rosvik)", lat: 65.430885, lon: 21.864992, heightM: 69.0, lowestDeg: 0.5, rangeKm: 240.0),
        "seoer": RadarSite(name: "Örnsköldsvik", lat: 63.639469, lon: 18.401882, heightM: 522.0, lowestDeg: 0.5, rangeKm: 240.0),
        "seosd": RadarSite(name: "Östersund", lat: 63.295078, lon: 14.759105, heightM: 466.0, lowestDeg: 0.5, rangeKm: 240.0),
        "noand": RadarSite(name: "Andøya", lat: 69.24139, lon: 16.00297, heightM: 441.0, lowestDeg: 0.5, rangeKm: 240.0),
        "nober": RadarSite(name: "Berlevåg", lat: 70.510652, lon: 29.018384, heightM: 474.0, lowestDeg: 0.5, rangeKm: 240.0),
        "nobml": RadarSite(name: "Bømlo", lat: 59.854, lon: 5.09, heightM: 102.0, lowestDeg: 0.5, rangeKm: 240.0),
        "nohas": RadarSite(name: "Hasvik", lat: 70.605194, lon: 22.442972, heightM: 446.5, lowestDeg: 0.5, rangeKm: 240.0),
        "nohfj": RadarSite(name: "Hafjell", lat: 61.23181, lon: 10.52731, heightM: 1080.0, lowestDeg: 0.5, rangeKm: 240.0),
        "nohgb": RadarSite(name: "Hægebostad", lat: 58.360145, lon: 7.16481, heightM: 631.0, lowestDeg: 0.5, rangeKm: 240.0),
        "nohur": RadarSite(name: "Hurum", lat: 59.627083, lon: 10.564472, heightM: 363.0, lowestDeg: 0.5, rangeKm: 240.0),
        "norsa": RadarSite(name: "Rissa", lat: 63.69, lon: 10.204, heightM: 616.0, lowestDeg: 0.5, rangeKm: 240.0),
        "norsg": RadarSite(name: "Finnmark (inland)", lat: 69.218605, lon: 23.439759, heightM: 604.1, lowestDeg: 0.5, rangeKm: 240.0),
        "norst": RadarSite(name: "Røst", lat: 67.5307, lon: 12.0986, heightM: 17.0, lowestDeg: 0.5, rangeKm: 240.0),
        "nosmn": RadarSite(name: "Sømna", lat: 65.21989, lon: 11.9926, heightM: 315.0, lowestDeg: 0.5, rangeKm: 240.0),
        "nosta": RadarSite(name: "Stad", lat: 62.187076, lon: 5.127454, heightM: 508.0, lowestDeg: 0.5, rangeKm: 240.0),
    ]

    /// The site a volume names: EUMETNET's node code, or DWD's bare three letters.
    static func site(_ code: String) -> RadarSite? {
        let lower = code.lowercased()
        return all[lower] ?? all["de" + lower]
    }

    /// A node code as the sweeps name its site: DWD's volumes write theirs
    /// without the country (core's `siteCode`).
    static func siteCode(_ code: String) -> String {
        let lower = code.lowercased()
        return all[lower] != nil || all["de" + lower] == nil ? lower : "de" + lower
    }

    /// The radar's country, ISO 3166 alpha-2 in lower case.
    static func countryOf(_ code: String) -> String {
        String(siteCode(code).prefix(2))
    }

    /// The country's flag, as the system draws it.
    static func flag(_ country: String) -> String {
        String(String.UnicodeScalarView(country.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1A5 + $0.value) }))
    }

    static let earthRadiusKm = 6371.0
    /// The 4/3 earth refraction bends a beam over.
    static let effectiveRadiusKm = 4.0 / 3.0 * earthRadiusKm

    /// Great-circle distance, km.
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = pow(sin(dLat / 2), 2) + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin(dLon / 2), 2)
        return 2 * earthRadiusKm * asin(min(1, sqrt(a)))
    }

    /// How high a beam's centre is above sea level this far out, km.
    static func beamHeightKm(range: Double, elevationDeg: Double, siteHeightM: Double) -> Double {
        let k = effectiveRadiusKm
        let theta = elevationDeg * .pi / 180
        return sqrt(range * range + k * k + 2 * range * k * sin(theta)) - k + siteHeightM / 1000
    }

    struct Contribution: Equatable, Identifiable {
        let code: String
        let name: String
        let distanceKm: Double?
        let lowestBeamKm: Double?
        let site: RadarSite?
        var id: String { code }
    }

    /// The radars a volume was built from, nearest first.
    static func contributions(_ codes: [String], lat: Double, lon: Double) -> [Contribution] {
        codes.map { code in
            guard let site = site(code) else {
                return Contribution(code: code, name: code.uppercased(), distanceKm: nil, lowestBeamKm: nil, site: nil)
            }
            let range = distanceKm(site.lat, site.lon, lat, lon)
            return Contribution(code: code, name: site.name, distanceKm: range,
                                lowestBeamKm: beamHeightKm(range: range, elevationDeg: site.lowestDeg, siteHeightM: site.heightM), site: site)
        }
        .sorted { ($0.distanceKm ?? .infinity) < ($1.distanceKm ?? .infinity) }
    }
}
