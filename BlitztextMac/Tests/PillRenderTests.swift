import AppKit
import SwiftUI
import XCTest

/// Renders the pill into PNGs for visual review. Skips when the output
/// directory cannot be created.
@MainActor
final class PillRenderTests: XCTestCase {
    /// Override with `PILL_RENDER_DIR`; defaults to a folder in the temp directory.
    private static var defaultDirectory: String {
        ProcessInfo.processInfo.environment["PILL_RENDER_DIR"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("pill-render")
    }

    private func outputDirectory() throws -> URL {
        let url = URL(fileURLWithPath: Self.defaultDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw XCTSkip("Cannot create render directory: \(error.localizedDescription)")
        }
        return url
    }

    private func render(_ name: String, state: PillVisualState, bands: [Float], to directory: URL) throws {
        // Light backdrop so the dark capsule and its shadow are visible.
        let view = PillStageView(state: state, bands: bands, flowTime: 1.3)
            .background(Color(white: 0.82))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "no image for \(name)")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testRenderPillStates() throws {
        let directory = try outputDirectory()
        try render("idle", state: .idle, bands: [], to: directory)
        try render("recording-quiet", state: .recording, bands: [0, 0, 0, 0, 0], to: directory)
        try render("recording-speaking", state: .recording, bands: [0.9, 0.7, 0.5, 0.6, 0.3], to: directory)
        try render("processing", state: .processing, bands: [], to: directory)
        try render("error", state: .error, bands: [], to: directory)
        for name in ["idle", "recording-quiet", "recording-speaking", "processing", "error"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).png").path))
        }
    }
}
