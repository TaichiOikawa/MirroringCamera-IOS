import SwiftUI

struct ContentView: View {
  @ObservedObject private var cameraManager = CameraManager.shared
  @State private var isScreenLocked = false
  @State private var showTimeLapseSheet = false
  @State private var showResolutionSheet = false
  @State private var showFPSSheet = false
  @State private var showSettings = false
  @ObservedObject private var wsManager = WebSocketManager.shared

  var body: some View {
    GeometryReader { geometry in
      let isLandscape = geometry.size.width > geometry.size.height

      ZStack {
        Color.black.edgesIgnoringSafeArea(.all)

        // カメラプレビューは常に1つだけ（if/else の外に置いて再生成を防止）
        CameraView(isScreenLocked: $isScreenLocked)
          .aspectRatio(isLandscape ? 16.0 / 9.0 : 9.0 / 16.0, contentMode: isLandscape ? .fill : .fit)
          .frame(
            width: isLandscape ? geometry.size.width - 240 : nil,
            height: isLandscape ? geometry.size.height : nil
          )
          .clipped()
          .position(
            x: geometry.size.width / 2,
            y: geometry.size.height / 2
          )
          .allowsHitTesting(false)

        // アクティブカメラ時の赤枠
        if wsManager.isActiveCamera {
          RoundedRectangle(cornerRadius: 0)
            .stroke(Color.red, lineWidth: 6)
            .edgesIgnoringSafeArea(.all)
            .allowsHitTesting(false)
        }

        // コントロールだけを縦横で切り替え
        if isLandscape {
          // 左パネル（絶対位置）
          VStack {
            leftPanel(geometry: geometry)
          }
          .frame(width: 120)
          .position(x: 60, y: geometry.size.height / 2)

          // 右パネル（絶対位置）
          VStack {
            rightPanel(geometry: geometry)
          }
          .frame(width: 120)
          .position(x: geometry.size.width - 60, y: geometry.size.height / 2)
        } else {
          VStack(spacing: 0) {
            topBar
              .padding(.top, geometry.safeAreaInsets.top + 22)

            Spacer()

            VStack(spacing: 0) {
              statusIndicator

              modeSelector
                .padding(.bottom, 8)

              bottomControls
            }
            .padding(.bottom, max(geometry.safeAreaInsets.bottom, 16))
          }
        }
      }
    }
    .edgesIgnoringSafeArea(.all)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      CameraManager.shared.setupVolumeShutter()
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
      CameraManager.shared.stopVolumeShutter()
    }
    .onChange(of: isScreenLocked) { locked in
      handleScreenLockChange(locked: locked)
    }
    .confirmationDialog("撮影間隔を選択", isPresented: $showTimeLapseSheet) {
      Button("0.5秒") { cameraManager.startTimeLapse(interval: 0.5) }
      Button("1秒") { cameraManager.startTimeLapse(interval: 1.0) }
      Button("2秒") { cameraManager.startTimeLapse(interval: 2.0) }
      Button("3秒") { cameraManager.startTimeLapse(interval: 3.0) }
      Button("5秒") { cameraManager.startTimeLapse(interval: 5.0) }
      Button("10秒") { cameraManager.startTimeLapse(interval: 10.0) }
    }
    .confirmationDialog("解像度を選択", isPresented: $showResolutionSheet) {
      ForEach(cameraManager.getSupportedResolutions().map { ($0.0.rawValue, $0.1, $0.0) },
              id: \.0) { _, name, preset in
        Button(name) { cameraManager.changeResolution(preset: preset) }
      }
    }
    .confirmationDialog("FPSを選択", isPresented: $showFPSSheet) {
      ForEach(cameraManager.getSupportedFPS(), id: \.self) { fps in
        Button("\(Int(fps)) FPS") { cameraManager.changeFPS(fps: fps) }
      }
    }
    .fullScreenCover(isPresented: $showSettings) {
      SettingsView()
    }
  }

  // MARK: - 横向き左パネル
  private func leftPanel(geometry: GeometryProxy) -> some View {
    VStack(spacing: 14) {
      Button(action: { showResolutionSheet = true }) {
        Text(cameraManager.resolutionName)
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundColor(.yellow)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.white.opacity(0.15))
          .cornerRadius(4)
      }

      Button(action: { showFPSSheet = true }) {
        Text("\(Int(cameraManager.currentFPS))")
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundColor(.yellow)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.white.opacity(0.15))
          .cornerRadius(4)
      }

      Button(action: { isScreenLocked.toggle() }) {
        Image(systemName: isScreenLocked ? "lock.fill" : "lock.open")
          .font(.system(size: 20))
          .foregroundColor(isScreenLocked ? .yellow : .white)
      }

      if ExternalDisplayStore.shared.isExternalDisplayConnected {
        Image(systemName: "tv.fill")
          .font(.system(size: 16))
          .foregroundColor(.green)
      }

      // バッテリー・温度
      VStack(spacing: 4) {
        HStack(spacing: 2) {
          Image(systemName: batteryIconName)
            .font(.system(size: 10))
            .foregroundColor(batteryColor)
          Text("\(cameraManager.batteryPercent)%")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
        }
        HStack(spacing: 2) {
          Image(systemName: "thermometer.medium")
            .font(.system(size: 10))
            .foregroundColor(cameraManager.thermalStateColor)
          Text(cameraManager.thermalStateLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(cameraManager.thermalStateColor)
        }
      }

      Button(action: { showSettings = true }) {
        Image(systemName: "gearshape.fill")
          .font(.system(size: 18))
          .foregroundColor(.white)
      }

      Circle()
        .fill(wsManager.isConnected ? Color.green : (wsManager.isConnecting ? Color.orange : Color.red.opacity(0.6)))
        .frame(width: 8, height: 8)

      VStack(spacing: 10) {
        ForEach(CameraMode.allCases, id: \.self) { mode in
          Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
              cameraManager.selectedMode = mode
            }
          }) {
            Text(mode.rawValue)
              .font(.system(size: 13, weight: cameraManager.selectedMode == mode ? .bold : .regular))
              .foregroundColor(cameraManager.selectedMode == mode ? .yellow : .white.opacity(0.5))
          }
          .disabled(shouldDisableMode(mode))
          .opacity(shouldDisableMode(mode) ? 0.3 : 1.0)
        }
      }

      Spacer()
    }
    .frame(width: 120)
    .padding(.top, geometry.safeAreaInsets.top + 10)
    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 12))
  }

  // MARK: - 横向き右パネル
  private func rightPanel(geometry: GeometryProxy) -> some View {
    VStack(spacing: 14) {
      Spacer()

      statusIndicator

      shutterButton

      Spacer()
    }
    .frame(width: 120)
    .padding(.top, geometry.safeAreaInsets.top + 10)
    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 12))
  }

  // MARK: - トップバー（縦向き用）
  private var topBar: some View {
    HStack(spacing: 16) {
      Button(action: { showResolutionSheet = true }) {
        Text(cameraManager.resolutionName)
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundColor(.yellow)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.white.opacity(0.15))
          .cornerRadius(4)
      }

      Button(action: { showFPSSheet = true }) {
        Text("\(Int(cameraManager.currentFPS))")
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundColor(.yellow)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.white.opacity(0.15))
          .cornerRadius(4)
      }

      Spacer()

      HStack(spacing: 10) {
        if ExternalDisplayStore.shared.isExternalDisplayConnected {
          HStack(spacing: 4) {
            Image(systemName: "tv.fill")
            Text("出力中")
          }
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.green)
        }

        HStack(spacing: 4) {
          Image(systemName: batteryIconName)
            .foregroundColor(batteryColor)
          Text("\(cameraManager.batteryPercent)%")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)

        HStack(spacing: 4) {
          Image(systemName: "thermometer.medium")
            .foregroundColor(cameraManager.thermalStateColor)
          Text(cameraManager.thermalStateLabel)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(cameraManager.thermalStateColor)
      }

      Spacer()

      Button(action: { showSettings = true }) {
        Image(systemName: "gearshape.fill")
          .font(.system(size: 18))
          .foregroundColor(.white)
      }

      Circle()
        .fill(wsManager.isConnected ? Color.green : (wsManager.isConnecting ? Color.orange : Color.red.opacity(0.6)))
        .frame(width: 8, height: 8)

      Button(action: { isScreenLocked.toggle() }) {
        Image(systemName: isScreenLocked ? "lock.fill" : "lock.open")
          .font(.system(size: 18))
          .foregroundColor(isScreenLocked ? .yellow : .white)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
  }

  // MARK: - ステータスインジケーター
  @ViewBuilder
  private var statusIndicator: some View {
    if cameraManager.isRecording {
      HStack(spacing: 6) {
        Circle()
          .fill(Color.red)
          .frame(width: 8, height: 8)
        Text(cameraManager.formattedRecordingTime)
          .font(.system(size: 15, weight: .medium, design: .monospaced))
          .foregroundColor(.white)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Color.red.opacity(0.3))
      .cornerRadius(16)
      .padding(.bottom, 4)
    } else if cameraManager.isTimeLapseActive {
      HStack(spacing: 6) {
        Image(systemName: "camera.fill")
          .foregroundColor(.orange)
        Text("\(cameraManager.timeLapseCount)枚")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.white)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Color.orange.opacity(0.3))
      .cornerRadius(16)
      .padding(.bottom, 4)
    }
  }

  // MARK: - モード選択
  private var modeSelector: some View {
    HStack(spacing: 20) {
      ForEach(CameraMode.allCases, id: \.self) { mode in
        Button(action: {
          withAnimation(.easeInOut(duration: 0.2)) {
            cameraManager.selectedMode = mode
          }
        }) {
          Text(mode.rawValue)
            .font(.system(size: 14, weight: cameraManager.selectedMode == mode ? .bold : .regular))
            .foregroundColor(cameraManager.selectedMode == mode ? .yellow : .white.opacity(0.5))
        }
        .disabled(shouldDisableMode(mode))
        .opacity(shouldDisableMode(mode) ? 0.3 : 1.0)
      }
    }
    .padding(.vertical, 8)
  }

  private func shouldDisableMode(_ mode: CameraMode) -> Bool {
    switch mode {
    case .photo:
      return cameraManager.isRecording || cameraManager.isTimeLapseActive
    case .video:
      return cameraManager.isTimeLapseActive
    case .timeLapse:
      return cameraManager.isRecording
    }
  }

  // MARK: - ボトムコントロール
  private var bottomControls: some View {
    HStack {
      Color.clear
        .frame(width: 48, height: 48)

      Spacer()

      shutterButton

      Spacer()

      Color.clear
        .frame(width: 48, height: 48)
    }
    .padding(.horizontal, 32)
  }

  // MARK: - シャッターボタン
  @ViewBuilder
  private var shutterButton: some View {
    switch cameraManager.selectedMode {
    case .photo:
      Button(action: { cameraManager.capturePhoto() }) {
        ZStack {
          Circle()
            .stroke(Color.white, lineWidth: 4)
            .frame(width: 72, height: 72)
          Circle()
            .fill(Color.white)
            .frame(width: 62, height: 62)
        }
      }

    case .video:
      Button(action: { cameraManager.toggleRecording() }) {
        ZStack {
          Circle()
            .stroke(Color.white, lineWidth: 4)
            .frame(width: 72, height: 72)
          if cameraManager.isRecording {
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.red)
              .frame(width: 28, height: 28)
          } else {
            Circle()
              .fill(Color.red)
              .frame(width: 62, height: 62)
          }
        }
      }

    case .timeLapse:
      Button(action: {
        if cameraManager.isTimeLapseActive {
          cameraManager.stopTimeLapse()
        } else {
          showTimeLapseSheet = true
        }
      }) {
        ZStack {
          Circle()
            .stroke(Color.white, lineWidth: 4)
            .frame(width: 72, height: 72)
          if cameraManager.isTimeLapseActive {
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.orange)
              .frame(width: 28, height: 28)
          } else {
            Circle()
              .fill(Color.orange)
              .frame(width: 62, height: 62)
              .overlay(
                Image(systemName: "timelapse")
                  .font(.system(size: 24, weight: .bold))
                  .foregroundColor(.white)
              )
          }
        }
      }
    }
  }

  // MARK: - バッテリーアイコン
  private var batteryIconName: String {
    let pct = cameraManager.batteryPercent
    if pct > 75 { return "battery.100" }
    if pct > 50 { return "battery.75" }
    if pct > 25 { return "battery.50" }
    return "battery.25"
  }

  private var batteryColor: Color {
    let pct = cameraManager.batteryPercent
    if pct > 20 { return .green }
    if pct > 10 { return .yellow }
    return .red
  }

  // MARK: - 画面固定
  private var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private func handleScreenLockChange(locked: Bool) {
    guard let window = keyWindow else {
      print("Error: Could not find any window")
      return
    }

    if locked {
      OrientationController.shared.lockCurrentOrientation(onWindow: window)
    } else {
      OrientationController.shared.unlockOrientation()
      OrientationController.shared.lockOrientation(to: .all, onWindow: window)
      // ロック解除後、プレビューの向きを現在のデバイス向きに再同期
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        CameraManager.shared.coordinator?.refreshPreviewOrientation()
      }
    }
  }
}
