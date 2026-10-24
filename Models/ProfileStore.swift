import SwiftUI
import AppKit
import Combine

// MARK: - Profile Store (Phase 14, Agent 2)

/// The person using the app: display name, optional photo, and whether
/// the first-launch welcome has been completed.
///
/// Deliberately NOT SwiftData:
/// - the name and the welcome flag live in UserDefaults
/// - the photo lives at Application Support/ResearchBase/profile.png
///
/// Like `AppearanceSettings`, this is a plain ObservableObject (no
/// @MainActor) so it can be created as a `@StateObject` in the App.
/// Every method that changes it is called from UI code on the main thread.
final class ProfileStore: ObservableObject {

    /// Name pre-filled in the welcome sheet. Matches the proposal.
    static let defaultDisplayName = "Gaurav"

    /// Longest side of the saved profile photo, in pixels.
    static let maxPhotoDimension: CGFloat = 256

    private enum Keys {
        static let displayName = "profile.displayName"
        static let hasCompletedWelcome = "profile.hasCompletedWelcome"
    }

    /// The saved name (already trimmed). May be empty if the user
    /// cleared the field in the welcome sheet.
    @Published private(set) var displayName: String

    /// The saved profile photo, or nil when there is none.
    @Published private(set) var avatarImage: NSImage?

    /// false = the welcome sheet should be showing.
    @Published private(set) var hasCompletedWelcome: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayName = defaults.string(forKey: Keys.displayName)
            ?? Self.defaultDisplayName
        hasCompletedWelcome = defaults.bool(forKey: Keys.hasCompletedWelcome)
        avatarImage = Self.loadSavedPhoto()
    }

    // MARK: Derived values

    /// The name to use in a greeting, or nil when there is no usable name.
    var greetingName: String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// First letter of the name, uppercased. "R" when there is no usable name.
    var initial: String {
        Self.initial(for: displayName)
    }

    /// Same rule for any text (the welcome sheet uses it for its draft name).
    static func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first(where: { $0.isLetter || $0.isNumber }) else {
            return "R"
        }
        return String(first).uppercased()
    }

    // MARK: Welcome flow

    /// Saves the welcome sheet's result and marks the welcome as done.
    /// `photo == nil` means "no photo" (an existing one is removed).
    func completeWelcome(name: String, photo: NSImage?) {
        setDisplayName(name)

        if let photo {
            // Unchanged photo (e.g. "Show again" then "Get started"):
            // nothing to re-encode.
            if photo !== avatarImage {
                setPhoto(photo)
            }
        } else {
            removePhoto()
        }

        hasCompletedWelcome = true
        defaults.set(true, forKey: Keys.hasCompletedWelcome)
    }

    /// Makes the welcome sheet appear again. Meant for a Settings button.
    /// The sheet pre-fills with the current name and photo.
    func showWelcomeAgain() {
        hasCompletedWelcome = false
        defaults.set(false, forKey: Keys.hasCompletedWelcome)
    }

    // MARK: Name

    /// Saves the name (trimmed).
    func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = trimmed
        defaults.set(trimmed, forKey: Keys.displayName)
    }

    // MARK: Photo

    /// Resizes (max 256 px) and saves the photo as profile.png.
    /// Returns false if it could not be saved; the old photo is kept then.
    @discardableResult
    func setPhoto(_ image: NSImage) -> Bool {
        guard
            let data = Self.pngData(from: image, maxDimension: Self.maxPhotoDimension),
            let directory = Self.supportDirectory(create: true)
        else {
            Swift.print("ResearchBase: Could not prepare the profile photo.")
            return false
        }

        do {
            try data.write(
                to: directory.appendingPathComponent("profile.png"),
                options: .atomic
            )
        } catch {
            Swift.print("ResearchBase: Could not save the profile photo: \(error)")
            return false
        }

        avatarImage = NSImage(data: data)
        return true
    }

    /// Deletes the saved photo, if any.
    func removePhoto() {
        avatarImage = nil

        guard
            let directory = Self.supportDirectory(create: false)
        else { return }

        let url = directory.appendingPathComponent("profile.png")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Swift.print("ResearchBase: Could not remove the profile photo: \(error)")
        }
    }

    // MARK: Files

    /// Application Support/ResearchBase
    private static func supportDirectory(create: Bool) -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: create
            )
            let directory = base.appendingPathComponent(
                "ResearchBase",
                isDirectory: true
            )
            if create {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            return directory
        } catch {
            Swift.print("ResearchBase: Application Support unavailable: \(error)")
            return nil
        }
    }

    private static func loadSavedPhoto() -> NSImage? {
        guard let directory = supportDirectory(create: false) else { return nil }
        let url = directory.appendingPathComponent("profile.png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: Image resizing

    /// Scales the image down so its longest side is at most
    /// `maxDimension` pixels (never up) and returns PNG data.
    /// Works in real pixels, so the result does not depend on the
    /// screen's scale factor.
    private static func pngData(
        from image: NSImage,
        maxDimension: CGFloat
    ) -> Data? {

        let sourceWidth: CGFloat
        let sourceHeight: CGFloat

        if let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) {
            sourceWidth = CGFloat(cgImage.width)
            sourceHeight = CGFloat(cgImage.height)
        } else {
            sourceWidth = image.size.width
            sourceHeight = image.size.height
        }

        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
        let pixelsWide = max(1, Int((sourceWidth * scale).rounded()))
        let pixelsHigh = max(1, Int((sourceHeight * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        // 1 point = 1 pixel for the saved file.
        rep.size = NSSize(width: pixelsWide, height: pixelsHigh)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh),
            from: .zero,
            operation: .copy,
            fraction: 1
        )

        return rep.representation(using: .png, properties: [:])
    }
}
