import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit

final class R2PlaybackBridge: NSObject, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private let playerChannel: FlutterMethodChannel
  private let playerProvider: (Int64) -> AVPlayer?
  private let attachTexture: (Int64, Bool) -> Void
  private let viewProvider: () -> UIView?
  private var session: String?
  private var playerId: Int64?
  private var player: AVPlayer?
  private var pipController: AVPictureInPictureController?
  private var pipLayer: AVPlayerLayer?
  private var pipObservation: NSKeyValueObservation?
  private var restoring = false
  private var commands: [(MPRemoteCommand, Any)] = []
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger,
       playerProvider: @escaping (Int64) -> AVPlayer?,
       attachTexture: @escaping (Int64, Bool) -> Void,
       viewProvider: @escaping () -> UIView?) {
    channel = FlutterMethodChannel(name: "app.r2gallery/playback", binaryMessenger: messenger)
    playerChannel = FlutterMethodChannel(name: "app.r2gallery/player", binaryMessenger: messenger)
    self.playerProvider = playerProvider
    self.attachTexture = attachTexture
    self.viewProvider = viewProvider
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    playerChannel.setMethodCallHandler { call, result in
      if call.method == "setKeepScreenOn" {
        let keep = call.arguments as? Bool == true && UIApplication.shared.applicationState == .active
        UIApplication.shared.isIdleTimerDisabled = keep
        result(keep)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
      object: nil, queue: .main) { _ in UIApplication.shared.isIdleTimerDisabled = false })
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main) { [weak self] _ in self?.textureVisible(false) })
    observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
      object: nil, queue: .main) { [weak self] _ in self?.textureVisible(true) })
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let token = args["session"] as? String else {
      result(FlutterError(code: "invalid_session", message: "再生状態を確認できません", details: nil))
      return
    }
    if call.method == "bind" {
      clear()
      guard let id = args["playerId"] as? NSNumber, let samePlayer = playerProvider(id.int64Value) else {
        result(FlutterError(code: "invalid_player", message: "再生器を確認できません", details: nil))
        return
      }
      session = token
      playerId = id.int64Value
      player = samePlayer
      installCommands(token)
      result(["pip": AVPictureInPictureController.isPictureInPictureSupported(), "background": true])
      return
    }
    guard session == token else { result(call.method == "enterPip" ? false : nil); return }
    switch call.method {
    case "update":
      let duration = (args["duration"] as? NSNumber)?.doubleValue ?? 0
      let position = (args["position"] as? NSNumber)?.doubleValue ?? 0
      let playing = args["playing"] as? Bool == true
      let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1
      // ロック画面にはファイル名・画像・署名URLを公開しない。
      MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: "R2 Gallery",
        MPMediaItemPropertyArtist: "非公開の動画",
        MPMediaItemPropertyPlaybackDuration: max(0, duration) / 1000,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, position) / 1000,
        MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0,
        MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      ]
      MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
      result(nil)
    case "clear": clear(); result(nil)
    case "visibility": textureVisible(args["foreground"] as? Bool == true); result(nil)
    case "enterPip":
      guard AVPictureInPictureController.isPictureInPictureSupported(),
            UIApplication.shared.applicationState == .active,
            let view = viewProvider(), let player = player else { result(false); return }
      stopPip()
      let frame = CGRect(x: (args["left"] as? NSNumber)?.doubleValue ?? 0,
                         y: (args["top"] as? NSNumber)?.doubleValue ?? 0,
                         width: (args["width"] as? NSNumber)?.doubleValue ?? 0,
                         height: (args["height"] as? NSNumber)?.doubleValue ?? 0)
      guard frame.width > 0, frame.height > 0, frame.width.isFinite, frame.height.isFinite,
            frame.origin.x.isFinite, frame.origin.y.isFinite else {
        result(false); return
      }
      let layer = AVPlayerLayer(player: player)
      layer.frame = frame
      layer.videoGravity = .resizeAspect
      view.layer.addSublayer(layer)
      pipLayer = layer
      let controller = AVPictureInPictureController(playerLayer: layer)
      controller?.delegate = self
      if #available(iOS 14.2, *) { controller?.canStartPictureInPictureAutomaticallyFromInline = false }
      pipController = controller
      restoring = false
      // Layerが窓へ接続された後に開始し、delegateの成功を実際のPiP状態として通知する。
      pipObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
        [weak self] observed, _ in
        DispatchQueue.main.async { [weak self, weak observed] in
          guard let self = self, self.session == token,
                let observed = observed, observed === self.pipController,
                observed.isPictureInPicturePossible else { return }
          self.pipObservation = nil
          observed.startPictureInPicture()
        }
      }
      result(controller != nil)
    case "exitPip": stopPip(); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func installCommands(_ token: String) {
    let center = MPRemoteCommandCenter.shared()
    func add(_ command: MPRemoteCommand, action: String) {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        guard let self = self, self.session == token else { return .commandFailed }
        self.command(action, token: token)
        return .success
      }
      commands.append((command, target))
    }
    add(center.playCommand, action: "play")
    add(center.pauseCommand, action: "pause")
    add(center.stopCommand, action: "stop")
    center.skipForwardCommand.preferredIntervals = [10]
    center.skipBackwardCommand.preferredIntervals = [10]
    add(center.skipForwardCommand, action: "forward")
    add(center.skipBackwardCommand, action: "rewind")
    center.changePlaybackPositionCommand.isEnabled = true
    let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self = self, self.session == token,
            let seek = event as? MPChangePlaybackPositionCommandEvent,
            seek.positionTime.isFinite, seek.positionTime >= 0 else { return .commandFailed }
      self.command("seek", token: token, position: seek.positionTime * 1000)
      return .success
    }
    commands.append((center.changePlaybackPositionCommand, seekTarget))
    center.togglePlayPauseCommand.isEnabled = true
    let toggle = center.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self = self, self.session == token else { return .commandFailed }
      self.command(self.player?.rate == 0 ? "play" : "pause", token: token)
      return .success
    }
    commands.append((center.togglePlayPauseCommand, toggle))
  }

  private func command(_ action: String, token: String, position: Double? = nil) {
    var args: [String: Any] = ["session": token, "action": action]
    if let position = position { args["position"] = position }
    // OSからもDart側の認証・世代判定を通す。ここでAVPlayer.play()を直接呼ばない。
    channel.invokeMethod("command", arguments: args)
  }

  private func textureVisible(_ visible: Bool) {
    guard let id = playerId else { return }
    attachTexture(id, visible)
    if !visible { UIApplication.shared.isIdleTimerDisabled = false }
  }

  private func stopPip() {
    pipObservation = nil
    pipController?.delegate = nil
    if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
    pipController = nil
    pipLayer?.player = nil
    pipLayer?.removeFromSuperlayer()
    pipLayer = nil
  }

  private func clear() {
    stopPip()
    textureVisible(UIApplication.shared.applicationState == .active)
    session = nil
    player = nil
    playerId = nil
    for (command, target) in commands { command.removeTarget(target); command.isEnabled = false }
    commands.removeAll()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    UIApplication.shared.isIdleTimerDisabled = false
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    pipEvent(true)
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    pipEvent(false)
    stopPip()
  }
  func pictureInPictureController(_ controller: AVPictureInPictureController,
      failedToStartPictureInPictureWithError error: Error) {
    pipEvent(false, failed: true)
    stopPip()
  }
  func pictureInPictureController(_ controller: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    restoring = true
    completionHandler(viewProvider() != nil && session != nil)
  }
  private func pipEvent(_ active: Bool, failed: Bool = false) {
    guard let token = session else { return }
    channel.invokeMethod("pipChanged", arguments: [
      "session": token, "active": active, "failed": failed, "restoring": restoring,
    ])
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    for (command, target) in commands { command.removeTarget(target) }
  }
}
