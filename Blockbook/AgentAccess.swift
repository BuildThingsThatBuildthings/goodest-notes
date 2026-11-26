import Foundation

enum AgentAccess: Equatable {
    case items(Set<LibraryReference>)
    case project(UUID)
    case library

    var canCreateCanvas: Bool {
        if case .items = self { return false }
        return true
    }

    var projectID: UUID? {
        if case let .project(id) = self { return id }
        return nil
    }

    func references(in library: Library) throws -> [LibraryReference] {
        switch self {
        case let .items(selected):
            return library.references.filter(selected.contains)
        case let .project(id):
            guard let project = library.allProjects.first(where: { $0.id == id }) else {
                throw AgentTools.AgentError.message("The shared project is no longer available.")
            }
            return project.entries.filter { library.title(for: $0) != nil }
        case .library:
            return library.references
        }
    }

    func conversionLibrary(_ library: Library, permitted: Set<LibraryReference>) -> Library {
        guard case .items = self else { return library }
        var scoped = library
        scoped.papers = library.papers.filter { permitted.contains(.init(.paper, $0.id)) }
        scoped.blocks = library.blocks.compactMap { source in
            guard permitted.contains(.init(.block, source.id)) else { return nil }
            var block = source
            if let parent = block.parentID, !permitted.contains(.init(.block, parent)) { block.parentID = nil }
            if let page = block.source, !permitted.contains(.init(.paper, page.documentID)) { block.source = nil }
            return block
        }
        return scoped
    }
}
