import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum QRCode {
    /// A QR code of `text` as a crisp bitmap: each module is `scale` pixels square.
    public static func cgImage(for text: String, scale: Int = 10) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
