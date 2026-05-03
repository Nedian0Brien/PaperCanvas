import Foundation
import Observation

@Observable
final class URLDownloader {
    var isDownloading = false
    var lastError: String?

    func download(from url: URL) async -> URL? {
        await MainActor.run { self.isDownloading = true; self.lastError = nil }
        defer { Task { @MainActor in self.isDownloading = false } }

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "URLDownloader", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }

            let filename = preferredFilename(for: url, response: response)
            let docs = try FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            let dest = docs.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            return nil
        }
    }

    private func preferredFilename(for url: URL, response: URLResponse) -> String {
        if let suggested = response.suggestedFilename, !suggested.isEmpty {
            return suggested.hasSuffix(".pdf") ? suggested : suggested + ".pdf"
        }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" {
            return last.hasSuffix(".pdf") ? last : last + ".pdf"
        }
        return "download-\(Int(Date().timeIntervalSince1970)).pdf"
    }
}
