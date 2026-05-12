import Foundation

struct FileEditorDocument {
    let fileID: String
    var title: String
    var remotePath: String
    var content: String = ""
    var originalContent: String = ""
    var remoteContentHash: String?
    var isLoading = false
    var errorMessage: String?
    var lastSavedAt: Date?
    var hasLoaded = false

    var isDirty: Bool {
        content != originalContent
    }

    var userFacingErrorMessage: String? {
        errorMessage.map(Self.userFacingErrorMessage)
    }

    static func userFacingErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String,
              !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return trimmed
        }
        return error.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func discardChanges() {
        content = originalContent
    }
}
