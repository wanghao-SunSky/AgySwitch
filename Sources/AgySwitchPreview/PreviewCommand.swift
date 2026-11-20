import AgySwitchUI
import AppKit

@main
struct PreviewCommand {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".preview", isDirectory: true)
        do {
            try PreviewGallery.render(to: output)
            print("Rendered eight SwiftUI previews at 2×.")
        } catch {
            FileHandle.standardError.write(Data("Preview rendering failed.\n".utf8))
            exit(1)
        }
    }
}
