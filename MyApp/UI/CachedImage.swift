import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Drop-in replacement for `AsyncImage` with a memory cache, a disk-backed URL cache,
/// ImageIO downsampling to the rendered size, and de-duplicated in-flight requests.
///
/// `AsyncImage` keeps no memory cache and decodes images at full size, so channel logos
/// re-download and re-decode every time a list row scrolls back into view.
struct CachedImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: AsyncImagePhase = .empty
    /// The rendered size, measured before loading so the image is decoded at that size.
    @State private var renderedSize: CGSize = .zero

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    init<I: View, P: View>(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.url = url
        self.content = { phase in Self.imageOrPlaceholder(phase, content: content, placeholder: placeholder) }
    }

    @ViewBuilder
    private static func imageOrPlaceholder<I: View, P: View>(
        _ phase: AsyncImagePhase,
        content: (Image) -> I,
        placeholder: () -> P
    ) -> _ConditionalContent<I, P> {
        if let image = phase.image {
            content(image)
        } else {
            placeholder()
        }
    }

    var body: some View {
        content(phase)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { renderedSize = $0 }
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        let maxPixelSize = ImagePipeline.pixelSize(for: renderedSize, scale: displayScale)
        if let cached = ImagePipeline.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            phase = .success(cached)
            return
        }
        phase = .empty
        do {
            let image = try await ImagePipeline.shared.image(for: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            phase = .success(image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

/// Shared image loading: URLCache-backed session, decoded-image memory cache, request coalescing.
nonisolated final class ImagePipeline: @unchecked Sendable {
    // @unchecked: mutable state is limited to `inFlight`, which is only touched under `lock`;
    // NSCache and URLSession are thread-safe.
    static let shared = ImagePipeline()

    enum PipelineError: Error {
        case badResponse
        case undecodable
    }

    /// Fallback when the rendered size isn't known yet.
    static let defaultMaxPixelSize = 1_200

    private let session: URLSession
    #if canImport(UIKit)
    /// Keyed by URL; an entry decoded at a larger size also serves smaller requests.
    private let memoryCache = NSCache<NSString, CacheEntry>()

    private final class CacheEntry {
        let image: UIImage
        let maxPixelSize: Int
        /// The source was smaller than the limit, so this is the full-resolution image.
        let isFullResolution: Bool

        init(image: UIImage, maxPixelSize: Int) {
            self.image = image
            self.maxPixelSize = maxPixelSize
            let longest = max(image.size.width, image.size.height) * image.scale
            isFullResolution = Int(longest) < maxPixelSize
        }
    }
    #endif
    private let lock = NSLock()
    private var inFlight: [String: Task<CGImage, Error>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 50 * 1024 * 1024,
                                          diskCapacity: 300 * 1024 * 1024,
                                          directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                                            .appendingPathComponent("ImagePipeline", isDirectory: true))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
        #if canImport(UIKit)
        memoryCache.totalCostLimit = 80 * 1024 * 1024
        #endif
    }

    /// Rounds the target pixel size up to a 64 px bucket so small layout differences share a cache entry.
    static func pixelSize(for size: CGSize, scale: CGFloat) -> Int {
        let longest = max(size.width, size.height) * max(scale, 1)
        guard longest > 1 else { return defaultMaxPixelSize }
        return min(4_096, Int((longest / 64).rounded(.up)) * 64)
    }

    private func key(_ url: URL, _ maxPixelSize: Int) -> String {
        "\(maxPixelSize)|\(url.absoluteString)"
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> Image? {
        #if canImport(UIKit)
        guard let entry = memoryCache.object(forKey: url.absoluteString as NSString),
              entry.maxPixelSize >= maxPixelSize || entry.isFullResolution else { return nil }
        return Image(uiImage: entry.image)
        #else
        nil
        #endif
    }

    func image(for url: URL, maxPixelSize: Int) async throws -> Image {
        let cgImage = try await decodedImage(for: url, maxPixelSize: maxPixelSize)
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #else
        return Image(decorative: cgImage, scale: 1)
        #endif
    }

    func cgImage(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        try await decodedImage(for: url, maxPixelSize: maxPixelSize)
    }

    /// Warms the caches for images about to scroll into view (e.g. the next 30 channel logos).
    func prefetch(_ urls: [URL], maxPixelSize: Int) {
        for url in urls where cachedImage(for: url, maxPixelSize: maxPixelSize) == nil {
            Task(priority: .utility) { _ = try? await self.decodedImage(for: url, maxPixelSize: maxPixelSize) }
        }
    }

    private func decodedImage(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        let cacheKey = key(url, maxPixelSize)
        let task: Task<CGImage, Error> = lock.withLock {
            if let existing = inFlight[cacheKey] { return existing }
            let session = session
            let created = Task.detached(priority: .userInitiated) {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw PipelineError.badResponse
                }
                guard let image = ImagePipeline.downsample(data, maxPixelSize: maxPixelSize) else {
                    throw PipelineError.undecodable
                }
                return image
            }
            inFlight[cacheKey] = created
            return created
        }
        defer { lock.withLock { inFlight[cacheKey] = nil } }
        let image = try await task.value
        #if canImport(UIKit)
        let urlKey = url.absoluteString as NSString
        if (memoryCache.object(forKey: urlKey)?.maxPixelSize ?? 0) < maxPixelSize {
            memoryCache.setObject(CacheEntry(image: UIImage(cgImage: image), maxPixelSize: maxPixelSize),
                                  forKey: urlKey, cost: image.bytesPerRow * image.height)
        }
        #endif
        return image
    }

    /// Decodes straight to a thumbnail no larger than `maxPixelSize`, never the full-size bitmap.
    private static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
