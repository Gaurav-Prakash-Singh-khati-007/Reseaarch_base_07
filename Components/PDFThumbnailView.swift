import SwiftUI
import PDFKit

struct PDFThumbnailView: NSViewRepresentable {

    let page: PDFPage
    let isSelected: Bool

    func makeNSView(context: Context) -> PDFThumbnailNSView {
        let view = PDFThumbnailNSView()

        view.page = page
        view.isSelected = isSelected

        return view
    }

    func updateNSView(
        _ nsView: PDFThumbnailNSView,
        context: Context
    ) {
        nsView.page = page
        nsView.isSelected = isSelected
        nsView.needsDisplay = true
    }
}

// MARK: - Thumbnail View

final class PDFThumbnailNSView: NSView {

    var page: PDFPage?
    var isSelected: Bool = false

    override func draw(_ dirtyRect: NSRect) {

        super.draw(dirtyRect)

        guard let page = page else {
            return
        }

        let bounds = self.bounds

        // Background
        NSColor(RBColor.surface).setFill()

        bounds.fill()

        // Space around the page
        let pageRect = bounds.insetBy(
            dx: 8,
            dy: 8
        )

        // White paper background
        NSColor.white.setFill()
        pageRect.fill()

        // Create thumbnail
        let thumbnail = page.thumbnail(
            of: pageRect.size,
            for: .mediaBox
        )

        // Calculate size that keeps the complete page visible
        let thumbnailSize = thumbnail.size

        let scale = min(
            pageRect.width / thumbnailSize.width,
            pageRect.height / thumbnailSize.height
        )

        let scaledWidth = thumbnailSize.width * scale
        let scaledHeight = thumbnailSize.height * scale

        let x = pageRect.midX - scaledWidth / 2
        let y = pageRect.midY - scaledHeight / 2

        let drawRect = NSRect(
            x: x,
            y: y,
            width: scaledWidth,
            height: scaledHeight
        )

        // Draw complete PDF page
        thumbnail.draw(
            in: drawRect,
            from: NSRect(
                origin: .zero,
                size: thumbnail.size
            ),
            operation: .sourceOver,
            fraction: 1.0
        )

        // Selection border
        if isSelected {

            let borderPath = NSBezierPath(
                roundedRect: pageRect,
                xRadius: 4,
                yRadius: 4
            )

            NSColor(RBColor.accent).setStroke()

            borderPath.lineWidth = 2

            borderPath.stroke()
        }
    }
}
