import AgySwitchCore
import AppKit
import SwiftUI

@MainActor
public enum PreviewGallery {
    private enum Failure: Error { case bitmap }

    private final class RetinaWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        override func convertToBacking(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2)
        }
        override func convertFromBacking(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX / 2, y: rect.minY / 2, width: rect.width / 2, height: rect.height / 2)
        }
    }

    public static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let time = 1_800_000_000.0
        let date = Date(timeIntervalSince1970: time)
        let accounts = [
            Account(accountID: String(repeating: "a", count: 64), alias: "personal", email: "lin@example.com"),
            Account(accountID: String(repeating: "b", count: 64), alias: "backup", email: "lin.backup@example.com"),
            Account(accountID: String(repeating: "c", count: 64), alias: "studio", email: "lin.studio@example.com",
                    cooldownUntil: time + 15_120, exhaustedReason: .resource)
        ]
        let scenarios: [(String, String, MenuFeedback?)] = [
            ("overview", accounts[0].email, .switchResult(target: accounts[0].alias, changed: true, offersReload: true)),
            ("managed", accounts[0].email, .switchResult(target: accounts[0].alias, changed: true, offersReload: true))
        ]
        for (name, currentEmail, feedback) in scenarios {
            let pool = PoolSnapshot(registry: Registry(accounts: accounts), currentEmail: currentEmail)
            for (variant, appearance, scheme) in [
                ("light", NSAppearance.Name.aqua, ColorScheme.light),
                ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)
            ] {
                for (language, suffix) in [(AppLanguage.zhHans, ""), (.en, "-en")] {
                    let model = MenuModel(pool: pool, automatic: true, listening: true,
                                          feedback: feedback, language: language)
                    model.showsAddAccount = name == "managed"
                    let view = MenuPopoverView(model: model, referenceDate: date)
                    try render(view, appearance: appearance, scheme: scheme,
                               to: directory.appendingPathComponent("\(name)\(suffix)-\(variant).png"))
                }
            }
        }
    }

    private static func render(_ view: MenuPopoverView, appearance: NSAppearance.Name, scheme: ColorScheme,
                               to file: URL) throws {
        guard let appearance = NSAppearance(named: appearance) else { throw Failure.bitmap }
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            let content = view
                .environment(\.colorScheme, scheme)
                .environment(\.controlActiveState, .key)
                .environment(\.displayScale, 2)
                .background(Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5)
                }
            let host = NSHostingView(rootView: content)
            host.appearance = appearance
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: NSSize(width: ceil(size.width), height: ceil(size.height)))
            let window = RetinaWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            host.wantsLayer = true
            host.layer?.contentsScale = 2
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // AppKit lays out native controls before caching the same hosted view at 2 px/pt.
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: Int(host.bounds.width * 2),
                                                pixelsHigh: Int(host.bounds.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                return
            }
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
        guard let png else { throw Failure.bitmap }
        try png.write(to: file, options: .atomic)
    }
}
