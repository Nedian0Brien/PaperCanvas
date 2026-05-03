import Foundation
import SwiftData

@MainActor
enum BundledSampleInstaller {
    private static let installedFlagKey = "BundledSampleInstaller.RaDA.v1"
    private static let resourceName = "RaDA"
    private static let resourceExtension = "pdf"
    private static let displayTitle = "RaDA: Retrieval-augmented Web Agent Planning with LLMs"

    static func installIfNeeded(into modelContext: ModelContext) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: installedFlagKey) { return }
        guard let bundleURL = Bundle.main.url(forResource: resourceName,
                                              withExtension: resourceExtension) else { return }
        do {
            let docs = try FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
            let dest = docs.appendingPathComponent("\(resourceName).\(resourceExtension)")
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: bundleURL, to: dest)
            }
            let bookmark = try? dest.bookmarkData()
            let paper = PaperDocument(title: displayTitle,
                                      bookmarkData: bookmark,
                                      sourceURLString: dest.path)
            modelContext.insert(paper)
            try modelContext.save()
            defaults.set(true, forKey: installedFlagKey)
        } catch {
            print("샘플 PDF 설치 실패: \(error.localizedDescription)")
        }
    }
}
