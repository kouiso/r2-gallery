import Flutter
import UIKit
import video_player_avfoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var playbackBridge: R2PlaybackBridge?
  private var privateStorageBridge: R2PrivateStorageBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "R2PrivateStorageBridge") {
      privateStorageBridge = R2PrivateStorageBridge(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "R2PlaybackBridge") {
      playbackBridge = R2PlaybackBridge(messenger: registrar.messenger(),
        playerProvider: { identifier in
          let plugin = engineBridge.pluginRegistry.valuePublished(byPlugin: "VideoPlayerPlugin") as? VideoPlayerPlugin
          return plugin?.r2Player(identifier: identifier)
        },
        attachTexture: { identifier, attached in
          let plugin = engineBridge.pluginRegistry.valuePublished(byPlugin: "VideoPlayerPlugin") as? VideoPlayerPlugin
          plugin?.r2SetTextureLayerAttached(identifier: identifier, attached: attached)
        },
        viewProvider: {
          UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController?.view
        })
    }
  }
}
