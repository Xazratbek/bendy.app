import Foundation
import Combine

final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let enabled = "enabled"
        static let styleID = "styleID"
        static let engageAngle = "engageAngle"
        static let perspectiveScale = "perspectiveScale"
        static let blurScale = "blurScale"
        static let shadowScale = "shadowScale"
        static let edgeScale = "edgeScale"
        static let soundEnabled = "soundEnabled"
        static let unfoldDuration = "unfoldDuration"
        static let bendCount = "bendCount"
        static let batterySaver = "batterySaver"
        static let customStyles = "customStyles"
        static let preferredDisplayID = "preferredDisplayID"
    }

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }

    @Published var styleID: String { didSet { defaults.set(styleID, forKey: Key.styleID) } }

    @Published var engageAngle: Double { didSet { defaults.set(engageAngle, forKey: Key.engageAngle) } }

    @Published var perspectiveScale: Double { didSet { defaults.set(perspectiveScale, forKey: Key.perspectiveScale) } }
    @Published var blurScale: Double { didSet { defaults.set(blurScale, forKey: Key.blurScale) } }
    @Published var shadowScale: Double { didSet { defaults.set(shadowScale, forKey: Key.shadowScale) } }
    @Published var edgeScale: Double { didSet { defaults.set(edgeScale, forKey: Key.edgeScale) } }

    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) } }

    @Published var unfoldDuration: Double { didSet { defaults.set(unfoldDuration, forKey: Key.unfoldDuration) } }

    /// Every lid-close-then-reopen cycle the controller has observed. Purely a
    /// novelty counter (mirrors trybendy's "N bends and counting"); it has no
    /// effect on the render.
    @Published var bendCount: Int { didSet { defaults.set(bendCount, forKey: Key.bendCount) } }

    /// When on battery, cap capture to a lower resolution and frame rate to
    /// save power. Ignored on AC.
    @Published var batterySaver: Bool { didSet { defaults.set(batterySaver, forKey: Key.batterySaver) } }

    /// User-saved variations on top of the three built-in styles. Stored as
    /// JSON because UserDefaults has no native support for Codable arrays.
    @Published private(set) var customStyles: [FoldStyle] {
        didSet {
            guard let data = try? JSONEncoder().encode(customStyles) else { return }
            defaults.set(data, forKey: Key.customStyles)
        }
    }

    /// 0 means "choose automatically" (built-in display if present, else the
    /// main display). Otherwise the CGDirectDisplayID of a specific screen.
    @Published var preferredDisplayID: Int { didSet { defaults.set(preferredDisplayID, forKey: Key.preferredDisplayID) } }

    /// All styles the picker can offer: the three built-ins plus anything the
    /// user has saved.
    var allStyles: [FoldStyle] { FoldStyle.all + customStyles }

    var style: FoldStyle {
        var s = allStyles.first { $0.id == styleID } ?? FoldStyle.named(styleID)
        s.perspective *= perspectiveScale
        s.blurRadius *= blurScale
        s.shadowStrength *= shadowScale
        s.edgeSoftness *= edgeScale
        return s
    }

    @discardableResult
    func saveCurrentAsCustomStyle(named name: String) -> FoldStyle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = style
        saved = FoldStyle(
            id: "custom-\(UUID().uuidString)",
            name: trimmed.isEmpty ? "Custom" : trimmed,
            blurb: "Your own saved variation.",
            perspective: saved.perspective, blurRadius: saved.blurRadius,
            darkening: saved.darkening, shadowStrength: saved.shadowStrength,
            vignette: saved.vignette, edgeSoftness: saved.edgeSoftness,
            cornerRadius: saved.cornerRadius, sheen: saved.sheen, curvature: saved.curvature
        )
        customStyles.append(saved)
        // The new entry already bakes in the current intensity sliders, so
        // reset them to neutral — otherwise selecting it would apply the
        // scaling twice.
        perspectiveScale = 1
        blurScale = 1
        shadowScale = 1
        edgeScale = 1
        styleID = saved.id
        return saved
    }

    func deleteCustomStyle(id: String) {
        customStyles.removeAll { $0.id == id }
        if styleID == id { styleID = FoldStyle.eclipse.id }
    }

    func recordBend() {
        bendCount += 1
    }

    func resetToDefaults() {
        for key in [Key.enabled, Key.styleID, Key.engageAngle, Key.perspectiveScale,
                    Key.blurScale, Key.shadowScale, Key.edgeScale, Key.soundEnabled,
                    Key.unfoldDuration, Key.batterySaver, Key.preferredDisplayID] {
            defaults.removeObject(forKey: key)
        }
        enabled = defaults.bool(forKey: Key.enabled)
        styleID = defaults.string(forKey: Key.styleID) ?? FoldStyle.eclipse.id
        engageAngle = defaults.double(forKey: Key.engageAngle)
        perspectiveScale = defaults.double(forKey: Key.perspectiveScale)
        blurScale = defaults.double(forKey: Key.blurScale)
        shadowScale = defaults.double(forKey: Key.shadowScale)
        edgeScale = defaults.double(forKey: Key.edgeScale)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        unfoldDuration = defaults.double(forKey: Key.unfoldDuration)
        batterySaver = defaults.bool(forKey: Key.batterySaver)
        preferredDisplayID = defaults.integer(forKey: Key.preferredDisplayID)
        // Bend count and saved custom styles are personal history, not
        // "appearance" — a reset shouldn't wipe them.
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.styleID: FoldStyle.eclipse.id,
            Key.engageAngle: 100.0,
            Key.perspectiveScale: 1.0,
            Key.blurScale: 1.0,
            Key.shadowScale: 1.0,
            Key.edgeScale: 1.0,
            Key.soundEnabled: false,
            Key.unfoldDuration: 1.0,
            Key.bendCount: 0,
            Key.batterySaver: true,
            Key.preferredDisplayID: 0,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        styleID = defaults.string(forKey: Key.styleID) ?? FoldStyle.eclipse.id
        engageAngle = defaults.double(forKey: Key.engageAngle)
        perspectiveScale = defaults.double(forKey: Key.perspectiveScale)
        blurScale = defaults.double(forKey: Key.blurScale)
        shadowScale = defaults.double(forKey: Key.shadowScale)
        edgeScale = defaults.double(forKey: Key.edgeScale)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        unfoldDuration = defaults.double(forKey: Key.unfoldDuration)
        bendCount = defaults.integer(forKey: Key.bendCount)
        batterySaver = defaults.bool(forKey: Key.batterySaver)
        preferredDisplayID = defaults.integer(forKey: Key.preferredDisplayID)
        if let data = defaults.data(forKey: Key.customStyles),
           let decoded = try? JSONDecoder().decode([FoldStyle].self, from: data) {
            customStyles = decoded
        } else {
            customStyles = []
        }
    }
}
