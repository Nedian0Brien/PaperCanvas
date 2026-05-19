import SwiftUI
import SwiftData
import UIKit

private enum LibrarySidebarSelection: Hashable {
    case all
    case pinned
    case notes
    case canvases
    case folder(UUID)
    case trash
}

private enum LibrarySortMode: String, CaseIterable, Identifiable {
    case recent
    case title
    case created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent:  return "최근 수정순"
        case .title:   return "제목순"
        case .created: return "생성순"
        }
    }

    var systemImage: String {
        switch self {
        case .recent:  return "clock"
        case .title:   return "textformat"
        case .created: return "calendar"
        }
    }
}

private enum LibraryDisplayMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: return "그리드"
        case .list: return "리스트"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PaperDocument.updatedAt, order: .reverse) private var papers: [PaperDocument]
    @Query(sort: \PaperFolder.name, order: .forward) private var folders: [PaperFolder]

    @State private var sidebarSelection: LibrarySidebarSelection? = .all
    @State private var showingFilePicker = false
    @State private var showingURLPrompt = false
    @State private var showingFolderPrompt = false
    @State private var urlInput = ""
    @State private var folderNameInput = ""
    @State private var downloader = URLDownloader()
    @State private var selectedPaper: PaperDocument?
    @State private var renamingPaper: PaperDocument?
    @State private var renamingFolder: PaperFolder?
    @State private var folderPendingDeletion: PaperFolder?
    @State private var renameInput = ""
    @State private var searchText = ""
    @State private var sortMode: LibrarySortMode = .recent
    @State private var displayMode: LibraryDisplayMode = .grid

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: Spacing.xl)]

    private var selectedScope: LibrarySidebarSelection {
        sidebarSelection ?? .all
    }

    private var activeFolders: [PaperFolder] {
        folders.filter { !$0.isDeleted }
    }

    private var deletedFolders: [PaperFolder] {
        folders
            .filter(\.isDeleted)
            .sorted { lhs, rhs in
                (lhs.deletedAt ?? .distantPast) > (rhs.deletedAt ?? .distantPast)
            }
    }

    private var activePapers: [PaperDocument] {
        papers.filter { paper in
            !paper.isDeleted && paper.folder?.isDeleted != true
        }
    }

    private var trashPapers: [PaperDocument] {
        papers.filter { paper in
            paper.isDeleted && paper.folder?.isDeleted != true
        }
    }

    private var visiblePapers: [PaperDocument] {
        let scoped: [PaperDocument]
        switch selectedScope {
        case .all:
            scoped = activePapers
        case .pinned:
            scoped = activePapers.filter(\.isPinned)
        case .notes:
            scoped = activePapers.filter { $0.documentKind == .note }
        case .canvases:
            scoped = activePapers.filter { $0.documentKind == .canvas }
        case .folder(let folderID):
            scoped = activePapers.filter { $0.folder?.id == folderID }
        case .trash:
            scoped = trashPapers
        }

        return sortedPapers(searchFiltered(scoped))
    }

    private var visibleDeletedFolders: [PaperFolder] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return deletedFolders }
        return deletedFolders.filter { folder in
            folder.name.localizedStandardContains(query)
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trashItemCount: Int {
        deletedFolders.count + trashPapers.count
    }

    private var selectedTitle: String {
        switch selectedScope {
        case .all:
            return "전체보기"
        case .pinned:
            return "고정됨"
        case .notes:
            return "노트"
        case .canvases:
            return "캔버스"
        case .folder(let folderID):
            return folder(namedBy: folderID)?.name ?? "폴더"
        case .trash:
            return "휴지통"
        }
    }

    private var selectedSystemImage: String {
        switch selectedScope {
        case .all:
            return "tray.full"
        case .pinned:
            return "pin"
        case .notes:
            return PaperDocumentKind.note.systemImage
        case .canvases:
            return PaperDocumentKind.canvas.systemImage
        case .folder:
            return "folder"
        case .trash:
            return "trash"
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("PaperCanvas")
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            NavigationStack {
                content
                    .navigationTitle(selectedTitle)
                    .toolbar { toolbarContent }
                    .searchable(text: $searchText, prompt: "노트 검색")
            }
        }
        .navigationSplitViewStyle(.balanced)
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
        .alert("이름 변경", isPresented: paperRenamePresented) {
            TextField("제목", text: $renameInput)
            Button("취소", role: .cancel) { clearRenameDraft() }
            Button("저장") { commitPaperRename() }
                .disabled(renameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("새 폴더", isPresented: $showingFolderPrompt) {
            TextField("폴더 이름", text: $folderNameInput)
            Button("취소", role: .cancel) { clearFolderDraft() }
            Button("생성") { commitFolderCreate() }
                .disabled(folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("폴더 이름 변경", isPresented: folderRenamePresented) {
            TextField("폴더 이름", text: $folderNameInput)
            Button("취소", role: .cancel) { clearFolderDraft() }
            Button("저장") { commitFolderRename() }
                .disabled(folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("폴더를 휴지통으로 이동할까요?",
               isPresented: folderDeletePresented,
               presenting: folderPendingDeletion) { folder in
            Button("취소", role: .cancel) { folderPendingDeletion = nil }
            Button("휴지통으로 이동", role: .destructive) {
                moveFolderToTrash(folder)
            }
        } message: { folder in
            Text("폴더와 그 안의 문서는 라이브러리에서 숨겨지고, 휴지통에서 복구할 수 있습니다.")
        }
        .overlay(alignment: .top) {
            if downloader.isDownloading {
                ProgressView("다운로드 중...")
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                    .chromeGlassRect(cornerRadius: Radius.l)
                    .padding(.top, Spacing.m)
            }
        }
        .fullScreenCover(item: $selectedPaper) { paper in
            RootSplitView(paper: paper)
        }
        .task {
            BundledSampleInstaller.installIfNeeded(into: modelContext)
            migrateLegacyDocumentKindsIfNeeded()
        }
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("라이브러리") {
                sidebarLink(
                    selection: .all,
                    title: "전체보기",
                    systemImage: "tray.full",
                    count: activePapers.count
                )

                sidebarLink(
                    selection: .pinned,
                    title: "고정됨",
                    systemImage: "pin",
                    count: activePapers.filter(\.isPinned).count
                )

                sidebarLink(
                    selection: .notes,
                    title: "노트",
                    systemImage: PaperDocumentKind.note.systemImage,
                    count: activePapers.filter { $0.documentKind == .note }.count
                )

                sidebarLink(
                    selection: .canvases,
                    title: "캔버스",
                    systemImage: PaperDocumentKind.canvas.systemImage,
                    count: activePapers.filter { $0.documentKind == .canvas }.count
                )

                sidebarLink(
                    selection: .trash,
                    title: "휴지통",
                    systemImage: "trash",
                    count: trashItemCount
                )
            }

            Section {
                ForEach(activeFolders) { folder in
                    folderSidebarLink(folder)
                }

                Button {
                    beginFolderCreate()
                } label: {
                    Label("새 폴더", systemImage: "folder.badge.plus")
                }
            } header: {
                Text("폴더")
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    beginFolderCreate()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("새 폴더")
            }
        }
    }

    @ViewBuilder
    private func sidebarLink(selection: LibrarySidebarSelection,
                             title: String,
                             systemImage: String,
                             count: Int) -> some View {
        NavigationLink(value: selection) {
            Label {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(count)")
                        .font(AppType.monoCaption)
                        .foregroundStyle(Color.Ink.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    @ViewBuilder
    private func folderSidebarLink(_ folder: PaperFolder) -> some View {
        if #available(iOS 26.0, *) {
            folderSidebarLinkBase(folder)
                .dropDestination(for: String.self) { items, _ in
                    _ = movePapers(withIDs: items, to: folder)
                }
        } else {
            folderSidebarLinkBase(folder)
        }
    }

    @ViewBuilder
    private func folderSidebarLinkBase(_ folder: PaperFolder) -> some View {
        sidebarLink(
            selection: .folder(folder.id),
            title: folder.name,
            systemImage: "folder",
            count: activePapers.filter { $0.folder?.id == folder.id }.count
        )
        .contextMenu {
            Button("이름 변경") {
                beginFolderRename(folder)
            }
            Button("삭제", role: .destructive) {
                folderPendingDeletion = folder
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if selectedScope == .trash {
            trashContent
        } else if activePapers.isEmpty {
            libraryEmptyState
        } else if visiblePapers.isEmpty {
            filteredEmptyState
        } else {
            documentCollection
        }
    }

    private var libraryEmptyState: some View {
        ContentUnavailableView {
            Label("문서가 없습니다", systemImage: "note.text")
        } description: {
            Text("새 노트를 만들거나 PDF를 가져오세요.")
        } actions: {
            HStack(spacing: Spacing.m) {
                newNoteMenu(label: "새 노트", systemImage: "doc.text")
                Button(action: createBlankCanvas) {
                    Label("새 캔버스", systemImage: "rectangle.on.rectangle")
                }
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
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(emptyStateTitle, systemImage: selectedSystemImage)
        } description: {
            Text(emptyStateDescription)
        } actions: {
            if case .folder = selectedScope {
                HStack(spacing: Spacing.m) {
                    newNoteMenu(label: "이 폴더에 새 노트",
                                systemImage: "doc.text")
                    Button(action: createBlankCanvas) {
                        Label("이 폴더에 새 캔버스", systemImage: "rectangle.on.rectangle")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var documentCollection: some View {
        ScrollView {
            switch displayMode {
            case .grid:
                LazyVGrid(columns: columns, spacing: Spacing.xl) {
                    ForEach(visiblePapers) { paper in
                        documentGridButton(for: paper)
                    }
                }
                .padding(Spacing.xl)
            case .list:
                LazyVStack(spacing: Spacing.s) {
                    ForEach(visiblePapers) { paper in
                        documentListButton(for: paper)
                    }
                }
                .padding(Spacing.xl)
            }
        }
    }

    private var trashContent: some View {
        let hasTrashItems = !visibleDeletedFolders.isEmpty || !visiblePapers.isEmpty
        return Group {
            if hasTrashItems {
                ScrollView {
                    LazyVStack(spacing: Spacing.s) {
                        ForEach(visibleDeletedFolders) { folder in
                            TrashFolderRow(folder: folder, documentCount: folder.documents.count) {
                                restoreFolder(folder)
                            }
                        }

                        ForEach(visiblePapers) { paper in
                            PaperListRow(paper: paper)
                                .contextMenu {
                                    Button("복구") {
                                        restorePaper(paper)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("복구") {
                                        restorePaper(paper)
                                    }
                                    .tint(.accentColor)
                                }
                        }
                    }
                    .padding(Spacing.xl)
                }
            } else {
                ContentUnavailableView {
                    Label("휴지통이 비어 있습니다", systemImage: "trash")
                } description: {
                    Text("삭제한 폴더와 문서는 이곳에서 복구할 수 있습니다.")
                }
            }
        }
    }

    private func documentGridButton(for paper: PaperDocument) -> some View {
        Button {
            selectedPaper = paper
        } label: {
            PaperCard(paper: paper)
        }
        .buttonStyle(.plain)
        .draggable(paper.id.uuidString) {
            PaperDragPreview(paper: paper)
        }
        .contextMenu {
            documentContextMenu(for: paper)
        }
    }

    private func documentListButton(for paper: PaperDocument) -> some View {
        Button {
            selectedPaper = paper
        } label: {
            PaperListRow(paper: paper)
        }
        .buttonStyle(.plain)
        .draggable(paper.id.uuidString) {
            PaperDragPreview(paper: paper)
        }
        .contextMenu {
            documentContextMenu(for: paper)
        }
    }

    @ViewBuilder
    private func documentContextMenu(for paper: PaperDocument) -> some View {
        Button {
            togglePinned(paper)
        } label: {
            Label(paper.isPinned ? "고정 해제" : "고정", systemImage: paper.isPinned ? "pin.slash" : "pin")
        }

        Button("이름 변경") {
            beginPaperRename(paper)
        }

        folderMoveMenu(for: paper)

        Button("삭제", role: .destructive) {
            movePaperToTrash(paper)
        }
    }

    @ViewBuilder
    private func folderMoveMenu(for paper: PaperDocument) -> some View {
        Menu("폴더로 이동") {
            Button {
                move(paper, to: nil)
            } label: {
                Label("폴더 없음", systemImage: paper.folder == nil ? "checkmark" : "tray")
            }

            ForEach(activeFolders) { folder in
                Button {
                    move(paper, to: folder)
                } label: {
                    Label(folder.name, systemImage: paper.folder?.id == folder.id ? "checkmark" : "folder")
                }
            }
        }
    }

    private var emptyStateTitle: String {
        if !normalizedSearchText.isEmpty {
            return "검색 결과 없음"
        }
        switch selectedScope {
        case .all:
            return "문서가 없습니다"
        case .pinned:
            return "고정된 문서가 없습니다"
        case .notes:
            return "노트가 없습니다"
        case .canvases:
            return "캔버스가 없습니다"
        case .folder:
            return "폴더가 비어 있습니다"
        case .trash:
            return "휴지통이 비어 있습니다"
        }
    }

    private var emptyStateDescription: String {
        if !normalizedSearchText.isEmpty {
            return "다른 제목, 폴더 이름, URL로 검색해 보세요."
        }
        switch selectedScope {
        case .all:
            return "빈 캔버스를 만들거나 PDF를 가져오세요."
        case .pinned:
            return "자주 쓰는 문서를 고정하면 이곳에 모입니다."
        case .notes:
            return "PDF를 가져오면 이곳에 모입니다."
        case .canvases:
            return "새 캔버스를 만들면 이곳에 모입니다."
        case .folder:
            return "문서를 이 폴더로 이동하거나 새 캔버스를 만드세요."
        case .trash:
            return "삭제한 폴더와 문서는 이곳에서 복구할 수 있습니다."
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selectedScope != .trash {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Picker("보기", selection: $displayMode) {
                    ForEach(LibraryDisplayMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 124)

                Menu {
                    Picker("정렬", selection: $sortMode) {
                        ForEach(LibrarySortMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } label: {
                    Label("정렬", systemImage: "arrow.up.arrow.down")
                }

                newNoteMenu(label: "새 노트", systemImage: "doc.text")

                Button(action: createBlankCanvas) {
                    Label("새 캔버스", systemImage: "rectangle.on.rectangle")
                }

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
    }

    @ViewBuilder
    private func newNoteMenu(label: String, systemImage: String) -> some View {
        Menu {
            ForEach(NotePageStyle.allCases) { style in
                Button {
                    createBlankNote(style: style)
                } label: {
                    Label(style.label, systemImage: style.systemImage)
                }
            }
        } label: {
            Label(label, systemImage: systemImage)
        }
        .accessibilityLabel(label)
    }

    private var paperRenamePresented: Binding<Bool> {
        Binding(
            get: { renamingPaper != nil },
            set: { isPresented in
                if !isPresented {
                    clearRenameDraft()
                }
            }
        )
    }

    private var folderRenamePresented: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { isPresented in
                if !isPresented {
                    clearFolderDraft()
                }
            }
        )
    }

    private var folderDeletePresented: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    folderPendingDeletion = nil
                }
            }
        )
    }

    private func searchFiltered(_ documents: [PaperDocument]) -> [PaperDocument] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return documents }
        return documents.filter { paper in
            paper.title.localizedStandardContains(query) ||
            paper.folder?.name.localizedStandardContains(query) == true ||
            paper.documentKind.label.localizedStandardContains(query) ||
            (paper.sourceURLString?.localizedStandardContains(query) ?? false)
        }
    }

    private func sortedPapers(_ documents: [PaperDocument]) -> [PaperDocument] {
        switch sortMode {
        case .recent:
            return documents.sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
        case .title:
            return documents.sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .created:
            return documents.sorted { lhs, rhs in
                lhs.createdAt > rhs.createdAt
            }
        }
    }

    private func folder(namedBy id: UUID) -> PaperFolder? {
        folders.first { $0.id == id }
    }

    private func paper(namedBy id: UUID) -> PaperDocument? {
        papers.first { $0.id == id }
    }

    private func selectedFolder() -> PaperFolder? {
        guard case .folder(let folderID) = selectedScope else { return nil }
        return activeFolders.first { $0.id == folderID }
    }

    private func createBlankCanvas() {
        let paper = PaperDocument(title: nextBlankTitle(base: "새 캔버스"), kind: .canvas)
        if let folder = selectedFolder() {
            paper.folder = folder
            folder.updatedAt = .now
        }
        modelContext.insert(paper)
        try? modelContext.save()
        selectedPaper = paper
    }

    private func createBlankNote(style: NotePageStyle) {
        let paper = PaperDocument(title: nextBlankTitle(base: "새 노트"),
                                  kind: .note,
                                  notePageStyle: style,
                                  notePageCount: 1)
        if let folder = selectedFolder() {
            paper.folder = folder
            folder.updatedAt = .now
        }
        modelContext.insert(paper)
        try? modelContext.save()
        selectedPaper = paper
    }

    private func nextBlankTitle(base: String) -> String {
        let existingTitles = Set(papers.map(\.title))
        guard existingTitles.contains(base) else { return base }

        var index = 2
        while existingTitles.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func nextFolderTitle() -> String {
        let base = "새 폴더"
        let existingNames = Set(folders.map(\.name))
        guard existingNames.contains(base) else { return base }

        var index = 2
        while existingNames.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
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
                                      kind: .note,
                                      bookmarkData: bookmark,
                                      sourceURLString: url.path)
            if let folder = selectedFolder() {
                paper.folder = folder
                folder.updatedAt = .now
            }
            modelContext.insert(paper)
            try? modelContext.save()
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
                                      kind: .note,
                                      bookmarkData: bookmark,
                                      sourceURLString: originalURLString)
            if let folder = selectedFolder() {
                paper.folder = folder
                folder.updatedAt = .now
            }
            modelContext.insert(paper)
            try? modelContext.save()
            selectedPaper = paper
        }
    }

    private func beginPaperRename(_ paper: PaperDocument) {
        renamingPaper = paper
        renameInput = paper.title
    }

    private func clearRenameDraft() {
        renamingPaper = nil
        renameInput = ""
    }

    private func commitPaperRename() {
        let title = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let paper = renamingPaper else {
            clearRenameDraft()
            return
        }
        paper.title = title
        paper.updatedAt = .now
        try? modelContext.save()
        clearRenameDraft()
    }

    private func beginFolderCreate() {
        folderNameInput = nextFolderTitle()
        showingFolderPrompt = true
    }

    private func beginFolderRename(_ folder: PaperFolder) {
        renamingFolder = folder
        folderNameInput = folder.name
    }

    private func clearFolderDraft() {
        showingFolderPrompt = false
        renamingFolder = nil
        folderNameInput = ""
    }

    private func commitFolderCreate() {
        let name = folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            clearFolderDraft()
            return
        }
        let folder = PaperFolder(name: name)
        modelContext.insert(folder)
        try? modelContext.save()
        sidebarSelection = .folder(folder.id)
        clearFolderDraft()
    }

    private func commitFolderRename() {
        let name = folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let folder = renamingFolder else {
            clearFolderDraft()
            return
        }
        folder.name = name
        folder.updatedAt = .now
        try? modelContext.save()
        clearFolderDraft()
    }

    private func togglePinned(_ paper: PaperDocument) {
        paper.isPinned.toggle()
        paper.pinnedAt = paper.isPinned ? .now : nil
        paper.updatedAt = .now
        try? modelContext.save()
    }

    private func move(_ paper: PaperDocument, to folder: PaperFolder?) {
        paper.folder = folder
        paper.updatedAt = .now
        folder?.updatedAt = .now
        try? modelContext.save()
    }

    private func movePapers(withIDs rawIDs: [String], to folder: PaperFolder) -> Bool {
        let movedPapers = rawIDs
            .compactMap(UUID.init(uuidString:))
            .compactMap(paper(namedBy:))
            .filter { !$0.isDeleted && $0.folder?.id != folder.id }

        guard !movedPapers.isEmpty else { return false }
        for paper in movedPapers {
            paper.folder = folder
            paper.updatedAt = .now
        }
        folder.updatedAt = .now
        try? modelContext.save()
        return true
    }

    private func movePaperToTrash(_ paper: PaperDocument) {
        paper.deletedAt = .now
        paper.isPinned = false
        paper.pinnedAt = nil
        paper.updatedAt = .now
        if selectedPaper?.id == paper.id {
            selectedPaper = nil
        }
        try? modelContext.save()
    }

    private func restorePaper(_ paper: PaperDocument) {
        paper.deletedAt = nil
        if paper.folder?.isDeleted == true {
            paper.folder = nil
        }
        paper.updatedAt = .now
        try? modelContext.save()
    }

    private func moveFolderToTrash(_ folder: PaperFolder) {
        folder.deletedAt = .now
        folder.updatedAt = .now
        if case .folder(let selectedID) = selectedScope, selectedID == folder.id {
            sidebarSelection = .trash
        }
        if renamingFolder?.id == folder.id {
            clearFolderDraft()
        }
        try? modelContext.save()
    }

    private func restoreFolder(_ folder: PaperFolder) {
        folder.deletedAt = nil
        folder.updatedAt = .now
        try? modelContext.save()
        sidebarSelection = .folder(folder.id)
    }

    private func migrateLegacyDocumentKindsIfNeeded() {
        var didChange = false
        for paper in papers where !paper.hasExplicitDocumentKind {
            paper.documentKind = paper.inferredLegacyDocumentKind
            didChange = true
        }
        if didChange {
            try? modelContext.save()
        }
    }
}

private struct PaperCard: View {
    let paper: PaperDocument
    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: UIImage?

    private var interfaceStyle: UIUserInterfaceStyle {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.Surface.fill
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: paper.documentKind.systemImage)
                            .foregroundStyle(Color.Ink.secondary)
                            .font(.largeTitle)
                    }
                }

                if paper.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .padding(8)
                }
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Radius.l))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l)
                    .stroke(Color.Rule.hairline)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(paper.title)
                    .font(AppType.callout)
                    .lineLimit(2)
                    .foregroundStyle(Color.Ink.primary)

                HStack(spacing: 4) {
                    Image(systemName: paper.documentKind.systemImage)
                    Text(paper.documentKind.label)
                }
                .font(AppType.caption)
                .foregroundStyle(Color.Ink.secondary)

                if let folderName = paper.folder?.name {
                    Text(folderName)
                        .font(AppType.caption)
                        .foregroundStyle(Color.Ink.secondary)
                        .lineLimit(1)
                }

                Text(paper.updatedAt, format: .relative(presentation: .named))
                    .font(AppType.caption)
                    .foregroundStyle(Color.Ink.secondary)
            }
        }
        .task(id: "\(paper.id.uuidString)-\(paper.updatedAt.timeIntervalSinceReferenceDate)-\(interfaceStyle.rawValue)") {
            let image = PaperThumbnailService.shared.currentThumbnail(for: paper, style: interfaceStyle)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}

private struct PaperListRow: View {
    let paper: PaperDocument

    var body: some View {
        HStack(spacing: Spacing.m) {
            ZStack {
                Color.Surface.fill
                Image(systemName: paper.documentKind.systemImage)
                    .foregroundStyle(Color.Ink.secondary)
            }
            .frame(width: 48, height: 64)
            .clipShape(.rect(cornerRadius: Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m)
                    .stroke(Color.Rule.hairline)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(paper.title)
                        .font(AppType.callout)
                        .lineLimit(1)
                        .foregroundStyle(Color.Ink.primary)

                    if paper.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }

                HStack(spacing: Spacing.s) {
                    Label(paper.documentKind.label, systemImage: paper.documentKind.systemImage)
                    if let folderName = paper.folder?.name {
                        Label(folderName, systemImage: "folder")
                    }
                }
                .font(AppType.caption)
                .foregroundStyle(Color.Ink.secondary)
                .lineLimit(1)
            }

            Spacer()

            Text(paper.updatedAt, format: .relative(presentation: .named))
                .font(AppType.caption)
                .foregroundStyle(Color.Ink.secondary)
        }
        .padding(Spacing.m)
        .background(Color.Surface.subtle)
        .clipShape(.rect(cornerRadius: Radius.l))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l)
                .stroke(Color.Rule.hairline)
        )
        .contentShape(.rect)
    }
}

private struct TrashFolderRow: View {
    let folder: PaperFolder
    let documentCount: Int
    let restore: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(Color.Ink.secondary)
                .frame(width: 48, height: 48)
                .background(Color.Surface.fill)
                .clipShape(.rect(cornerRadius: Radius.m))

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(AppType.callout)
                    .foregroundStyle(Color.Ink.primary)

                Text("\(documentCount)개 문서")
                    .font(AppType.caption)
                    .foregroundStyle(Color.Ink.secondary)
            }

            Spacer()

            Button(action: restore) {
                Label("복구", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
        }
        .padding(Spacing.m)
        .background(Color.Surface.subtle)
        .clipShape(.rect(cornerRadius: Radius.l))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l)
                .stroke(Color.Rule.hairline)
        )
        .contextMenu {
            Button("복구", action: restore)
        }
    }
}

private struct PaperDragPreview: View {
    let paper: PaperDocument

    var body: some View {
        Label(paper.title, systemImage: paper.documentKind.systemImage)
            .font(AppType.callout)
            .lineLimit(1)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Color.Surface.subtle)
            .clipShape(.rect(cornerRadius: Radius.m))
    }
}
