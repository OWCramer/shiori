import Kingfisher
import UIKit

/// Steam logos sit on a wide transparent canvas: this crops them to the mark itself (as the
/// launch cover does), so a logo fills the space it's given and the text under it sits
/// right below it. Kingfisher caches the cropped image.
struct TrimmedLogoProcessor: ImageProcessor {
    let identifier = "com.owencramer.vnhub.trimmed-logo"

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        let image: KFCrossPlatformImage?
        switch item {
        case let .image(decoded): image = decoded
        case let .data(data): image = DefaultImageProcessor.default.process(item: .data(data), options: options)
        }
        guard let image else { return nil }
        return GameLibrary.trimmingTransparentMargins(image) ?? image
    }
}
