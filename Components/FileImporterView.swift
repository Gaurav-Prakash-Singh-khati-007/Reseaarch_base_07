import SwiftUI
import UniformTypeIdentifiers

struct FileImporterView: View {

    let onSelect: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {

        VStack(spacing: 16) {

            Image(systemName: "doc.text")
                .font(.system(size: 30))
                .foregroundStyle(RBColor.accent)

            Text("Select Research Paper")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("Choose a PDF from your Mac.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)

            Button("Choose PDF") {
                choosePDF()
            }
            .buttonStyle(RBPrimaryButtonStyle())

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(RBColor.secondaryText)
        }
        .frame(width: 420, height: 260)
        .background(RBColor.background)
    }

    private func choosePDF() {

        let panel = NSOpenPanel()

        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK,
           let url = panel.url {

            onSelect(url)
        }
    }
}
