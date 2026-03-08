import AVFoundation
import UIKit

/// 外部ディスプレイにカメラ映像を表示するView（AVSampleBufferDisplayLayer使用）
final class ExternalCameraView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}
