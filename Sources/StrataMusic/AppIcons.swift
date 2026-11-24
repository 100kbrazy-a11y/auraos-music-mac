import AppKit
import CoreImage

/// the Dock icon in other colours. The picture is recoloured when the app starts or when you pick one.
/// (macOS shows the icon of the app file itself when the app isn't running, so this only changes the icon while Strata is open.)
@MainActor
enum AppIcons {
    struct Variant: Identifiable { let id: String; let name: String; let dark: (Double, Double, Double); let light: (Double, Double, Double) }

    static let variants: [Variant] = [
        Variant(id: "original", name: "Original", dark: (0, 0, 0), light: (1, 1, 1)),
        Variant(id: "violet", name: "Violet", dark: (0.16, 0.06, 0.34), light: (1, 1, 1)),
        Variant(id: "ocean", name: "Ocean", dark: (0.03, 0.17, 0.33), light: (0.88, 0.97, 1)),
        Variant(id: "sunset", name: "Sunset", dark: (0.40, 0.10, 0.10), light: (1, 0.95, 0.85)),
        Variant(id: "forest", name: "Forest", dark: (0.04, 0.22, 0.14), light: (0.92, 1, 0.94)),
        Variant(id: "rose", name: "Rose", dark: (0.42, 0.07, 0.25), light: (1, 0.93, 0.96)),
    ]

    private static var original: NSImage? = NSApp.applicationIconImage?.copy() as? NSImage
    private static let context = CIContext()

    static func apply(_ id: String) {
        guard let v = variants.first(where: { $0.id == id }), let base = original else { return }
        if v.id == "original" { NSApp.applicationIconImage = base; return }
        guard let tiff = base.tiffRepresentation, let input = CIImage(data: tiff) else { return }
        // the icon is black with a white note: black becomes the dark colour, white the light one, and the rounded corners stay see-through
        let out = input.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: v.dark.0, green: v.dark.1, blue: v.dark.2),
            "inputColor1": CIColor(red: v.light.0, green: v.light.1, blue: v.light.2),
        ])
        guard let cg = context.createCGImage(out, from: input.extent) else { return }
        NSApp.applicationIconImage = NSImage(cgImage: cg, size: base.size)
    }

    static func applySaved() { apply(UserDefaults.standard.string(forKey: "appIcon") ?? "original") }
}
