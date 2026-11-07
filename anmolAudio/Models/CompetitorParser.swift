import Foundation

struct CompetitorParser {
    static func parse(json: Any, defaultName: String) -> EQPreset? {
        guard let dict = json as? [String: Any] else { return nil }
        
        // Extract basic metadata or fallbacks
        let name = dict["name"] as? String ?? defaultName
        let preamp = (dict["preamp"] as? NSNumber)?.floatValue ?? 0.0
        let headphone = dict["headphone"] as? String ?? "Imported"
        let source = dict["source"] as? String ?? "Competitor App"
        
        // Look for bands array
        guard let bandsArray = dict["bands"] as? [[String: Any]] else {
            return nil
        }
        
        var parsedBands: [EQBand] = []
        for b in bandsArray {
            let rawFreq = (b["frequency"] as? NSNumber ?? b["freq"] as? NSNumber)?.floatValue ?? 0.0
            let rawGain = (b["gain"] as? NSNumber)?.floatValue ?? 0.0
            let rawQ = (b["q"] as? NSNumber ?? b["Q"] as? NSNumber)?.floatValue ?? 0.71
            let typeString = (b["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "peak"

            guard rawFreq.isFinite, rawGain.isFinite, rawQ.isFinite,
                  rawFreq >= 10.0, rawFreq <= 22000.0, rawQ > 0.001 else {
                continue
            }

            let filterType: EQBand.FilterType
            switch typeString {
            case "lowshelf", "low_shelf", "low shelf", "lsc", "ls":
                filterType = .lowShelf
            case "highshelf", "high_shelf", "high shelf", "hsc", "hs":
                filterType = .highShelf
            case "peak", "pk", "peaking", "bell":
                filterType = .peak
            default:
                if typeString.hasPrefix("low") && !typeString.contains("pass") {
                    filterType = .lowShelf
                } else if typeString.hasPrefix("high") && !typeString.contains("pass") {
                    filterType = .highShelf
                } else {
                    filterType = .peak
                }
            }

            parsedBands.append(EQBand(type: filterType, frequency: rawFreq, gain: rawGain, q: rawQ))
        }
        
        guard !parsedBands.isEmpty else { return nil }
        return EQPreset(name: name, headphone: headphone, source: source, preamp: preamp, bands: parsedBands)
    }
}
