import AppKit
import SwiftUI

/// The app's icon, drawn in code: the notch at the top of a desktop glow, over a limit ring with a
/// spark at its heart. `TokenNotch --icon folder.iconset` writes every size iconutil needs; build-app.sh turns that into
/// AppIcon.icns.
struct AppIconArt: View {
    // A canvas of 1024 with the tile inset 100 on each side, as macOS icons are laid out.
    private let tile: CGFloat = 824
    private static let orange = Color(red: 0.96, green: 0.52, blue: 0.36)
    private static let pink = Color(red: 0.88, green: 0.36, blue: 0.62)
    private static let blue = Color(red: 0.36, green: 0.55, blue: 1.0)
    private static let violet = Color(red: 0.55, green: 0.40, blue: 0.95)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
        ZStack(alignment: .top) {
            backdrop
            notchAndRing
        }
        .frame(width: tile, height: tile)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 2))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
        .frame(width: 1024, height: 1024)
    }

    /// A desktop picture's colors: deep blue into violet, warm at the bottom.
    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.42), Color(red: 0.36, green: 0.22, blue: 0.58),
                                    Color(red: 0.92, green: 0.50, blue: 0.42)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Self.blue.opacity(0.55), .clear], center: UnitPoint(x: 0.1, y: 0.25),
                           startRadius: 0, endRadius: tile * 0.6)
            RadialGradient(colors: [Self.orange.opacity(0.6), .clear], center: UnitPoint(x: 0.9, y: 1.0),
                           startRadius: 0, endRadius: tile * 0.6)
        }
    }

    /// The closed notch with a large ring below it on the backdrop.
    private var notchAndRing: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 46, bottomTrailingRadius: 46, style: .continuous)
                .fill(.black).frame(width: 380, height: 104)
            ring(size: 420, width: 64).padding(.top, 230)
        }
    }

    /// A limit gauge: a track and a bright arc about three-quarters round, with a spark at its heart.
    private func ring(size: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: width)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(AngularGradient(colors: [Self.blue, Self.violet, Self.pink, Self.orange],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(260)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Spark().fill(.white).frame(width: size * 0.36, height: size * 0.36)
        }
        .frame(width: size, height: size)
    }

    /// A four-pointed spark.
    struct Spark: Shape {
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, w = r * 0.22
            var path = Path()
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
            path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
            path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
            return path
        }
    }

    /// Writes icon_16x16.png … icon_512x512@2x.png into an .iconset folder.
    @MainActor static func writeIconset(to folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: AppIconArt())
                renderer.scale = CGFloat(size * scale) / 1024
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }
}
