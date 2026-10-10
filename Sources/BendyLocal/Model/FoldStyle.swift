import Foundation

struct FoldStyle: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let blurb: String

    var perspective: Double

    var blurRadius: Double

    var darkening: Double

    var shadowStrength: Double

    var vignette: Double

    var edgeSoftness: Double

    var cornerRadius: Double

    var sheen: Double

    var curvature: Double

    static let satin = FoldStyle(
        id: "satin",
        name: "Silk",
        blurb: "Smooth and glossy, with light gliding across the desktop.",
        perspective: 0.85,
        blurRadius: 300,
        darkening: 0.10,
        shadowStrength: 0.50,
        vignette: 0.45,
        edgeSoftness: 0.060,
        cornerRadius: 0.030,
        sheen: 0.40,
        curvature: 0.22
    )

    static let eclipse = FoldStyle(
        id: "eclipse",
        name: "Shade",
        blurb: "Deep shadow. The desktop dims as it settles toward the hinge.",
        perspective: 1.00,
        blurRadius: 380,
        darkening: 0.40,
        shadowStrength: 1.00,
        vignette: 1.00,
        edgeSoftness: 0.055,
        cornerRadius: 0.028,
        sheen: 0.08,
        curvature: 0.14
    )

    static let glacier = FoldStyle(
        id: "glacier",
        name: "Frost",
        blurb: "Frosted glass. Everything softens before it disappears.",
        perspective: 0.75,
        blurRadius: 620,
        darkening: 0.08,
        shadowStrength: 0.35,
        vignette: 0.35,
        edgeSoftness: 0.075,
        cornerRadius: 0.034,
        sheen: 0.22,
        curvature: 0.28
    )

    static let all: [FoldStyle] = [.satin, .eclipse, .glacier]

    static func named(_ id: String) -> FoldStyle {
        all.first { $0.id == id } ?? .satin
    }
}
