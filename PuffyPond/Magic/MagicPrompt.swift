import Foundation

/// The words Magic mode gives the diffusion model. Built by the app only: kids never type a prompt.
nonisolated struct MagicPrompt: Equatable {
    let positive: String
    let negative: String

    static let negative = "scary, dark, violent, blood, text, watermark, ugly, blurry, realistic photo"

    static func make(template: TemplateKind?, brushes: [CritterKind]) -> MagicPrompt {
        var text = template.map(subject) ?? "a magical underwater pond scene"
        var seen = Set<CritterKind>()
        for brush in brushes where seen.insert(brush).inserted {
            text += ", " + style(of: brush)
        }
        text += ", children's book illustration, bright, whimsical, high quality"
        return MagicPrompt(positive: text, negative: negative)
    }

    private static func subject(_ template: TemplateKind) -> String {
        switch template {
        case .fish: return "a cute colorful fish"
        case .turtle: return "a friendly sea turtle"
        case .duck: return "a little yellow duck"
        }
    }

    private static func style(of brush: CritterKind) -> String {
        switch brush {
        case .jellyfish: return "soft watercolor"
        case .snail: return "thick impasto oil paint"
        case .seahorse: return "elegant ink calligraphy"
        case .pufferfish: return "playful splatter art"
        case .frog: return "dotted pointillism"
        case .octopus: return "bold gouache brushwork"
        }
    }
}
