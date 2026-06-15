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
            // 运行时 opt-in（默认关）：仅 env KLINE_SEED_FIXTURE=1 时 seed fixture，使运行时验收矩阵可在真
            // composition root 跑。seed 在 AppContainer.init 内（SettingsStore 构造前，settings 不 stale）+
            // 全空 guard（不破坏真实数据）。Release 二进制无 seed 代码（AppContainer 内 seed 块 #if DEBUG）。
            #if DEBUG
            let seedFixtures = ProcessInfo.processInfo.environment["KLINE_SEED_FIXTURE"] == "1"
            #else
            let seedFixtures = false
            #endif
            let container = try AppContainer(config: cfg, debugSeedFixtures: seedFixtures)
            _container = State(initialValue: container)
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
