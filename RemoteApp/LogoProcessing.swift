import RemoteKit
import UIKit

/// Bereitet ein gewähltes Foto als Kachel-Logo vor: höchstens 640 px, PNG (behält Transparenz),
/// notfalls JPEG, damit es unter `HomeApp.maxLogoBytes` bleibt.
enum LogoProcessing {
    static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let maxSide: CGFloat = 640
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        if let png = resized.pngData(), png.count <= HomeApp.maxLogoBytes {
            return png
        }
        if let jpeg = resized.jpegData(compressionQuality: 0.85), jpeg.count <= HomeApp.maxLogoBytes {
            return jpeg
        }
        return nil
    }
}
