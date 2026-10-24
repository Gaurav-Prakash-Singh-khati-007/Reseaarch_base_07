import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Profile Avatar (Phase 14, Agent 2)

/// Round avatar: the photo if there is one, otherwise the initial on
/// the accent color. Reused by Home, the welcome sheet and (later)
/// Settings.
struct ProfileAvatarView: View {

    let image: NSImage?
    let initial: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(RBColor.accent)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                // Sized to the avatar circle on purpose (not body text),
                // so it deliberately does not follow the text-size setting.
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(RBColor.background)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(RBColor.border, lineWidth: 1)
        )
    }
}

// MARK: - Welcome Sheet

/// First-launch welcome. Presented by ContentView while
/// `ProfileStore.hasCompletedWelcome` is false. It cannot be dismissed
/// any other way than "Get started".
struct WelcomeSheetView: View {

    @EnvironmentObject private var profile: ProfileStore

    @State private var draftName = ""
    @State private var draftPhoto: NSImage?
    @State private var photoError: String?
    @State private var didSeed = false

    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 14) {

            Text("Welcome to ResearchBase")
                .font(RBFont.title(.semibold))
                .foregroundStyle(RBColor.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Who is working here? This stays on your Mac.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)
                .multilineTextAlignment(.center)

            ProfileAvatarView(
                image: draftPhoto,
                initial: ProfileStore.initial(for: draftName),
                size: 64
            )
            .padding(.vertical, 6)

            HStack(spacing: 10) {
                secondaryButton(
                    draftPhoto == nil ? "Choose photo…" : "Change photo…"
                ) {
                    choosePhoto()
                }

                if draftPhoto != nil {
                    secondaryButton("Remove") {
                        draftPhoto = nil
                        photoError = nil
                    }
                }
            }

            if let photoError {
                Text(photoError)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.warning)
                    .multilineTextAlignment(.center)
            }

            TextField("Your name", text: $draftName)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .onSubmit { confirm() }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .fill(RBColor.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .stroke(RBColor.border, lineWidth: 1)
                )

            Button {
                confirm()
            } label: {
                Text("Get started")
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 440)
        .background(RBColor.elevatedSurface)
        // First launch: no Esc / click-away dismissal.
        .interactiveDismissDisabled(true)
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            draftName = profile.displayName
            draftPhoto = profile.avatarImage
            nameFocused = true
        }
    }

    // MARK: Actions

    private func confirm() {
        profile.completeWelcome(name: draftName, photo: draftPhoto)
        // hasCompletedWelcome is now true, so ContentView closes the sheet.
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose a profile photo"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let image = NSImage(contentsOf: url) {
            draftPhoto = image
            photoError = nil
        } else {
            photoError = "That file could not be opened as an image."
        }
    }

    private func secondaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(RBGhostButtonStyle())
    }
}
