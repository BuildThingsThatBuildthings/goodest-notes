import Foundation

enum DraftText {
    static func read(_ id: UUID?) -> String? {
        id.flatMap { UserDefaults.standard.string(forKey: "page-draft-" + $0.uuidString) }
    }

    static func save(_ value: String, for id: UUID?) {
        if let id { UserDefaults.standard.set(value, forKey: "page-draft-" + id.uuidString) }
    }

    static func clear(_ id: UUID?) {
        if let id { UserDefaults.standard.removeObject(forKey: "page-draft-" + id.uuidString) }
    }
}
