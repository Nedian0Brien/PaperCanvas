import SwiftUI
import SwiftData
import UIKit

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PaperDocument.updatedAt, order: .reverse) private var papers: [PaperDocument]

    @State private var showingFilePicker = false
    @State private var showingURLPrompt = false
    @State private var urlInput = ""
    @State private var downloader = URLDownloader()
    @State private var selectedPaper: PaperDocument?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 24)]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("PaperCanvas")
                .toolbar { toolbarContent }
                .fileImporter(isPresented: $showingFilePicker,
                              allowedContentTypes: [.pdf],
                              allowsMultipleSelection: false,
                              onCompletion: handleFileImport)
                .alert("URL에서 PDF 불러오기", isPresented: $showingURLPrompt) {
                    TextField("https://...", text: $urlInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("취소", role: .cancel) { urlInput = "" }
                    Button("불러오기") { handleURLDownload() }
                } message: {
                    Text("PDF 파일의 직접 링크를 입력하세요.")
                }
                .overlay(alignment: .top) {
                    if downloader.isDownloading {
                        ProgressView("다운로드 중…")
                            .padding(12)
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                            .padding(.top, 12)
                    }
                }
        }
        .fullScreenCover(item: $selectedPaper) { paper in
            RootSplitView(paper: paper)
        }
        .task {
            BundledSampleInstaller.installIfNeeded(into: modelContext)
        }
    }

    @ViewBuilder
    private var content: some View {
        if papers.isEmpty {
            ContentUnavailableView {
                Label("논문이 없습니다", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("파일에서 PDF를 가져오거나 URL에서 다운로드하세요.")
            } actions: {
                HStack(spacing: 12) {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("파일 열기", systemImage: "folder")
                    }
                    Button {
                        showingURLPrompt = true
                    } label: {
                        Label("URL", systemImage: "link")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(papers) { paper in
                        Button {
                            selectedPaper = paper
                        } label: {
                            PaperCard(paper: paper)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("삭제", role: .destructive) {
                                deletePaper(paper)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingFilePicker = true
            } label: {
                Label("파일 열기", systemImage: "folder")
            }
            Button {
                showingURLPrompt = true
            } label: {
                Label("URL에서 불러오기", systemImage: "link")
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try? url.bookmarkData()
            let title = url.deletingPathExtension().lastPathComponent
            let paper = PaperDocument(title: title,
                                      bookmarkData: bookmark,
                                      sourceURLString: url.path)
            modelContext.insert(paper)
            selectedPaper = paper
        case .failure(let error):
            print("불러오기 실패: \(error.localizedDescription)")
        }
    }

    private func handleURLDownload() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else { return }
        let originalURLString = url.absoluteString
        urlInput = ""
        Task {
            guard let local = await downloader.download(from: url) else { return }
            let title = local.deletingPathExtension().lastPathComponent
            let bookmark = try? local.bookmarkData()
            let paper = PaperDocument(title: title,
                                      bookmarkData: bookmark,
                                      sourceURLString: originalURLString)
            modelContext.insert(paper)
            selectedPaper = paper
        }
    }

    private func deletePaper(_ paper: PaperDocument) {
        PaperThumbnailService.shared.invalidate(for: paper)
        modelContext.delete(paper)
    }
}

private struct PaperCard: View {
    let paper: PaperDocument
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color(.tertiarySystemFill)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                        .font(.largeTitle)
                }
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator)))

            VStack(alignment: .leading, spacing: 2) {
                Text(paper.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(paper.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: paper.id) {
            await PaperThumbnailService.shared.generateIfNeeded(for: paper)
            thumbnail = PaperThumbnailService.shared.thumbnail(for: paper)
        }
    }
}
