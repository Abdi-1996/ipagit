# Video → Live Photo

Native iPhone app that converts the centered 3 seconds of a selected video into an Apple Live Photo and saves it to Photos.

- SwiftUI
- PhotosUI picker
- AVFoundation
- JPEG Apple MakerNote asset identifier
- QuickTime content identifier
- Timed `com.apple.quicktime.still-image-time` metadata track
- `PHAssetResourceType.pairedVideo`

The GitHub Actions workflow builds an unsigned IPA for sideload signing.
