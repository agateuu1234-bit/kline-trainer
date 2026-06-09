import SwiftUI
import KlineTrainerContracts
import KlineTrainerPersistence

@main
struct KlineTrainerApp: App {
    @State private var container: AppContainer?
    @State private var initError: Error?

    @MainActor
    init() {
        do {
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let cfg = AppConfig(dbPath: support.appendingPathComponent("app.sqlite"),
                                cacheRootDir: caches.appendingPathComponent("training-sets"),
                                backendBaseURL: URL(string: "http://kline-trainer.local")!)  // TODO(NAS) PR11-R1：部署后替换
            _container = State(initialValue: try AppContainer(config: cfg))
        } catch {
            _initError = State(initialValue: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let c = container {
                AppRootView(router: c.router, settings: c.settings, api: c.api, cache: c.cache, acceptance: c.acceptance)
            } else {
                AppLaunchErrorView(message: (initError as? AppError)?.userMessage ?? "应用数据初始化失败")
            }
        }
    }
}
