import SwiftUI

struct AppLaunchErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
            Text("启动失败").font(.headline)
            Text(message).font(.callout).multilineTextAlignment(.center)
        }
        .padding()
    }
}
