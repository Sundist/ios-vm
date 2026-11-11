import SwiftUI
import UIKit
import VMCore

/// Shows the VNC framebuffer and turns touches into absolute pointer events.
struct QEMUScreen: UIViewRepresentable {
    let session: QEMUSession

    func makeUIView(context: Context) -> QEMUScreenUIView {
        let view = QEMUScreenUIView()
        view.session = session
        return view
    }

    func updateUIView(_ view: QEMUScreenUIView, context: Context) {
        view.session = session
    }
}

final class QEMUScreenUIView: UIView {
    weak var session: QEMUSession?
    private var displayLink: CADisplayLink?
    private var lastGeneration: UInt64 = .max
    private var imageSize = CGSize.zero
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.6
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        tap.require(toFail: longPress)
        for recognizer in [tap, twoFingerTap, longPress, pan, scroll] { addGestureRecognizer(recognizer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            let link = CADisplayLink(target: self, selector: #selector(refresh))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    // MARK: Rendering

    @objc private func refresh() {
        guard let framebuffer = session?.rfb?.framebuffer, framebuffer.generation != lastGeneration else { return }
        lastGeneration = framebuffer.generation
        let image: CGImage? = framebuffer.withPixels { pointer, width, height, bytesPerRow in
            guard let pointer, width > 0, height > 0 else { return nil }
            let data = Data(bytes: pointer, count: bytesPerRow * height) as CFData
            guard let provider = CGDataProvider(data: data) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        if let image {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
            imageSize = CGSize(width: image.width, height: image.height)
        }
    }

    // MARK: Coordinates

    private func guestPoint(_ location: CGPoint) -> (x: Int, y: Int)? {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        let x = (location.x - origin.x) / scale
        let y = (location.y - origin.y) / scale
        let cx = Int(min(max(x, 0), imageSize.width - 1))
        let cy = Int(min(max(y, 0), imageSize.height - 1))
        return (cx, cy)
    }

    // MARK: Gestures

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let p = guestPoint(recognizer.location(in: self)) else { return }
        let (x, y) = (p.x, p.y)
        session?.click(at: x, y)
    }

    @objc private func twoFingerTapped(_ recognizer: UITapGestureRecognizer) {
        guard let p = guestPoint(recognizer.location(in: self)) else { return }
        let (x, y) = (p.x, p.y)
        session?.click(at: x, y, button: 4)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let p = guestPoint(recognizer.location(in: self)) else { return }
        let (x, y) = (p.x, p.y)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session?.click(at: x, y, button: 4)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let p = guestPoint(recognizer.location(in: self)) else { return }
        let (x, y) = (p.x, p.y)
        switch recognizer.state {
        case .began:
            session?.pointerMove(to: x, y)
            session?.pointerButton(1, down: true)
            dragging = true
        case .changed:
            session?.pointerMove(to: x, y)
        case .ended, .cancelled, .failed:
            if dragging {
                session?.pointerMove(to: x, y)
                session?.pointerButton(1, down: false)
                dragging = false
            }
        default:
            break
        }
    }

    private var scrollAccumulator: CGFloat = 0

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began {
            scrollAccumulator = 0
            if let p = guestPoint(recognizer.location(in: self)) { session?.pointerMove(to: p.x, p.y) }
        }
        let dy = recognizer.translation(in: self).y
        recognizer.setTranslation(.zero, in: self)
        scrollAccumulator += dy
        let steps = Int(scrollAccumulator / 24)
        if steps != 0 {
            session?.scroll(steps: steps)
            scrollAccumulator -= CGFloat(steps) * 24
        }
    }
}
