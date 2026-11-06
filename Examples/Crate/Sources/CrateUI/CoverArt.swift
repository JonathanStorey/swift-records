#if canImport(SwiftUI)
import CrateModels
import ImageIO
import SwiftUI

/// Album art drawn from the title, so the sample crate has covers without shipping images.
struct CoverArtView: View {
    var title: String
    var artist: String
    var year: Int

    /// A palette chosen from the title, the same on every device.
    private var hues: (Double, Double) {
        let seed = title.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return (Double(seed % 360) / 360, Double((seed / 7) % 360) / 360)
    }

    var body: some View {
        let (first, second) = hues
        ZStack {
            LinearGradient(
                colors: [Color(hue: first, saturation: 0.65, brightness: 0.85), Color(hue: second, saturation: 0.8, brightness: 0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // A record sliding out of the sleeve.
            ZStack {
                Circle().fill(.black.opacity(0.85))
                ForEach(1..<6) { ring in
                    Circle().stroke(.white.opacity(0.08), lineWidth: 2).padding(CGFloat(ring) * 22)
                }
                Circle().fill(Color(hue: second, saturation: 0.5, brightness: 0.95)).frame(width: 150, height: 150)
                Circle().fill(.black).frame(width: 14, height: 14)
            }
            .frame(width: 440, height: 440)
            .offset(x: 150, y: 40)
            VStack(alignment: .leading, spacing: 10) {
                Spacer()
                Text(title)
                    .font(.system(size: 54, weight: .heavy, design: .serif))
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                Text(artist.uppercased())
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .tracking(3)
                Text(String(year))
                    .font(.system(size: 22, weight: .regular, design: .monospaced))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .shadow(radius: 6)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: 600, height: 600)
        .clipped()
    }
}

enum CoverArt {
    /// A 600-point square PNG of the drawn cover.
    @MainActor
    static func png(title: String, artist: String, year: Int) -> Data? {
        let renderer = ImageRenderer(content: CoverArtView(title: title, artist: artist, year: year))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// An album's cover, or a placeholder while it has none.
struct CoverImage: View {
    var data: Data?
    var size: CGFloat

    var body: some View {
        Group {
            if let data, let image = Self.image(data) {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "opticaldisc").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 16))
    }

    static func image(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Image(decorative: image, scale: 1)
    }
}
#endif
