import SwiftUI
import Combine

// MARK: - Global app state
//
// Authentication is no longer handled here. The card key checked against the
// license server is the credential, and `LicenseManager` owns that state. What
// remains here is model selection and the camera route.

@MainActor
final class AppState: ObservableObject {

    /// The live instance, so views hosted in a separate `UIWindow` (the overlay)
    /// can read the same state without relying on the SwiftUI environment.
    /// Assigned by the app entry point.
    static private(set) var shared: AppState!

    // Routing
    @Published var showCamera = false

    // Model
    @Published var models: [ModelItem] = []
    @Published var selectedModel: ModelItem? = nil
    @Published var modelError: String? = nil

    init() {
        if AppState.shared == nil { AppState.shared = self }
        refreshModels()
    }

    // MARK: Models

    func refreshModels() {
        let found = ModelLoader.discoverModels()
        models = found
        if let current = selectedModel,
           !found.contains(where: { $0.id == current.id }) {
            // Selection disappeared -> fall back to the most accurate model.
            selectedModel = found.first
        } else if selectedModel == nil {
            selectedModel = found.first
        }
    }

    func importModel(from url: URL) {
        do {
            let saved = try ModelLoader.importModel(from: url)
            modelError = nil
            refreshModels()
            if let match = models.first(where: { $0.url.path == saved.path }) {
                selectedModel = match
            }
        } catch {
            modelError = "导入失败：\(error.localizedDescription)"
        }
    }

    func select(_ item: ModelItem) {
        selectedModel = item
        modelError = nil
    }
}
