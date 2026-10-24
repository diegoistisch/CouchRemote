import Foundation
import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Findet das größte offizielle Icon einer Webseite, so wie ein Browser:
/// 1. Web-App-Manifest (`<link rel="manifest">`, Icons meist bis 512 px)
/// 2. `<link rel="apple-touch-icon">` bzw. `<link rel="icon" sizes="…">` im HTML
/// 3. sonst `/apple-touch-icon.png`
/// 4. sonst der Favicon-Dienst von Google (für Seiten wie Crunchyroll, die automatische Abrufe
///    blockieren). Dabei wird nur der Domainname übertragen; das Bild muss mindestens 96 px groß sein.
/// Ergebnisse werden pro Host zwischengespeichert (auch über Neustarts).
public actor IconResolver {
    public static let shared = IconResolver()

    private var cache: [String: URL] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private static let defaultsKey = "iconCache.v2"

    /// Kleinere Icons sehen auf dem Fernseher verwaschen aus → dann lieber der Name.
    private static let minimumSize = 96

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        cache = stored.compactMapValues(URL.init(string:))
    }

    public func iconURL(for page: URL) async -> URL? {
        guard let host = page.host?.lowercased() else { return nil }
        if let cached = cache[host] { return cached }
        if let running = inFlight[host] { return await running.value }

        let task = Task { await Self.resolve(page) }
        inFlight[host] = task
        let result = await task.value
        inFlight[host] = nil

        if let result {
            cache[host] = result
            UserDefaults.standard.set(cache.mapValues(\.absoluteString), forKey: Self.defaultsKey)
        }
        return result
    }

    // MARK: - Suche

    private struct Candidate {
        let url: URL
        let size: Int
        let score: Int
    }

    private static func request(_ url: URL, timeout: TimeInterval = 8) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("de-AT,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private static func resolve(_ page: URL) async -> URL? {
        var candidates: [Candidate] = []

        if let (data, response) = try? await URLSession.shared.data(for: request(page)) {
            let head = data.prefix(600_000) // Icons und Manifest stehen im <head>
            let html = String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self)
            let base = response.url ?? page

            if let best = bestLinkIcon(in: html, base: base) {
                candidates.append(best)
            }
            if let manifestURL = manifestURL(in: html, base: base),
               let (manifestData, manifestResponse) = try? await URLSession.shared.data(for: request(manifestURL)),
               let best = bestManifestIcon(in: manifestData, base: manifestResponse.url ?? manifestURL) {
                candidates.append(best)
            }
        }

        if let best = candidates.max(by: { $0.score < $1.score }) {
            return best.url
        }

        for path in ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"] {
            if let url = URL(string: path, relativeTo: page)?.absoluteURL, await isImage(url) {
                return url
            }
        }

        if let host = page.host,
           let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=256"),
           await imagePixelSize(url) >= minimumSize {
            return url
        }
        return nil
    }

    /// Kantenlänge eines Bildes in Pixeln (0, wenn es nicht geladen werden kann).
    private static func imagePixelSize(_ url: URL) async -> Int {
        guard let (data, response) = try? await URLSession.shared.data(for: request(url, timeout: 6)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return min(width, height)
    }

    private static func isImage(_ url: URL) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(for: request(url, timeout: 5)),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && (http.mimeType?.hasPrefix("image/") ?? false) && data.count > 500
    }

    // MARK: - HTML

    /// Alle `<link>`-Tags als Attribut-Wörterbücher.
    private static func linkTags(in html: String) -> [[String: String]] {
        guard let linkRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attributeRegex = try? NSRegularExpression(
                pattern: "([a-zA-Z:-]+)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)") else { return [] }

        return linkRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            var attributes: [String: String] = [:]
            for attribute in attributeRegex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let keyRange = Range(attribute.range(at: 1), in: tag),
                      let valueRange = Range(attribute.range(at: 2), in: tag) else { continue }
                var value = String(tag[valueRange])
                if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
                attributes[tag[keyRange].lowercased()] = value.replacingOccurrences(of: "&amp;", with: "&")
            }
            return attributes
        }
    }

    private static func largestSize(_ sizes: String?) -> Int? {
        sizes?.lowercased()
            .split(separator: " ")
            .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
            .max()
    }

    private static func isUsable(_ href: String, type: String?) -> Bool {
        // SVG kann AsyncImage nicht anzeigen.
        !href.lowercased().contains(".svg") && !(type?.contains("svg") ?? false)
    }

    private static func httpURL(_ href: String, base: URL) -> URL? {
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func bestLinkIcon(in html: String, base: URL) -> Candidate? {
        var best: Candidate?
        for attributes in linkTags(in: html) {
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"], !href.isEmpty,
                  isUsable(href, type: attributes["type"]) else { continue }
            let rels = rel.split(separator: " ")
            let isTouchIcon = rels.contains { $0.hasPrefix("apple-touch-icon") }
            let isIcon = rels.contains("icon")
            guard isTouchIcon || isIcon else { continue }

            let size = largestSize(attributes["sizes"]) ?? (isTouchIcon ? 180 : 32)
            guard size >= minimumSize, let url = httpURL(href, base: base) else { continue }

            // Touch-Icons sind für Kacheln gemacht (eigener Hintergrund, keine Transparenz-Tricks).
            let candidate = Candidate(url: url, size: size, score: size + (isTouchIcon ? 50 : 0))
            if best == nil || candidate.score > best!.score { best = candidate }
        }
        return best
    }

    private static func manifestURL(in html: String, base: URL) -> URL? {
        linkTags(in: html)
            .first { $0["rel"]?.lowercased().split(separator: " ").contains("manifest") == true }
            .flatMap { $0["href"] }
            .flatMap { httpURL($0, base: base) }
    }

    private struct Manifest: Decodable {
        struct Icon: Decodable {
            let src: String
            let sizes: String?
            let type: String?
            let purpose: String?
        }
        let icons: [Icon]?
    }

    private static func bestManifestIcon(in data: Data, base: URL) -> Candidate? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        var best: Candidate?
        for icon in manifest.icons ?? [] {
            guard isUsable(icon.src, type: icon.type),
                  let size = largestSize(icon.sizes), size >= minimumSize,
                  let url = httpURL(icon.src, base: base) else { continue }
            // "maskable" hat viel Rand für runde Masken → "any" bevorzugen.
            let isMaskableOnly = icon.purpose?.lowercased() == "maskable"
            let candidate = Candidate(url: url, size: size, score: size - (isMaskableOnly ? 100 : 0) + 60)
            if best == nil || candidate.score > best!.score { best = candidate }
        }
        return best
    }

    // MARK: - Für Tests

    /// Bestes Icon aus den `<link>`-Tags (ohne Manifest). Öffentlich für Tests.
    public static func bestIcon(in html: String, base: URL) -> URL? {
        bestLinkIcon(in: html, base: base)?.url
    }

    /// Bestes Icon aus einem Web-App-Manifest. Öffentlich für Tests.
    public static func bestIcon(inManifest data: Data, base: URL) -> URL? {
        bestManifestIcon(in: data, base: base)?.url
    }
}

// MARK: - Icon-Ansicht

/// Icon einer Webseite mit eigenem Platzhalter, solange keins gefunden wurde.
public struct WebsiteIcon<Fallback: View>: View {
    private let page: URL
    private let cornerRadius: CGFloat
    private let fallback: () -> Fallback

    @State private var iconURL: URL?

    public init(page: URL, cornerRadius: CGFloat, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.page = page
        self.cornerRadius = cornerRadius
        self.fallback = fallback
    }

    public var body: some View {
        Group {
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    } else {
                        fallback()
                    }
                }
            } else {
                fallback()
            }
        }
        .task(id: page) {
            iconURL = await IconResolver.shared.iconURL(for: page)
        }
    }
}

// MARK: - Bilder aus Daten (eigene Logos)

public extension Image {
    /// SwiftUI-Bild aus PNG/JPEG-Daten, auf iOS und macOS.
    init?(logoData: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: logoData) else { return nil }
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: logoData) else { return nil }
        self.init(nsImage: image)
        #else
        return nil
        #endif
    }
}

public enum LogoData {
    /// Seitenverhältnis (Breite/Höhe) eines Logos, um breite Schriftzüge anders zu platzieren als quadratische Icons.
    public static func aspectRatio(_ data: Data) -> CGFloat? {
        #if canImport(UIKit)
        guard let size = UIImage(data: data)?.size, size.height > 0 else { return nil }
        return size.width / size.height
        #elseif canImport(AppKit)
        guard let size = NSImage(data: data)?.size, size.height > 0 else { return nil }
        return size.width / size.height
        #else
        return nil
        #endif
    }
}
