import LanChatCore
import SwiftUI

struct LanChatApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("LanChat") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

// 诊断模式：输出本机网络身份信息后退出（open -n LanChat.app --env LANCHAT_DIAG=1 --stdout <文件>）
if ProcessInfo.processInfo.environment["LANCHAT_DIAG"] != nil {
    print(Diagnostics.report())
    exit(0)
}
LanChatApp.main()
