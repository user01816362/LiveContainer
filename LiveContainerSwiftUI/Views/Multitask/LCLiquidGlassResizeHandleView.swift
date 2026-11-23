//
//  LCLiquidGlassResizeHandleView.swift
//  LiveContainer
//

import Observation
import SwiftUI
import UIKit

/// Shared observable state driving the Liquid Glass corner resize grabber.
@MainActor
@Observable
final class LCLiquidGlassResizeHandleState {
    var isResizing: Bool = false
    var windowCornerRadius: CGFloat = 18.0
}

/// Concentric bottom-right curved arc pill matching the iPadOS Liquid Glass window resize handle.
struct LCResizeCornerArcShape: Shape {
    var windowCornerRadius: CGFloat
    var edgeInset: CGFloat
    var thickness: CGFloat
    var legLength: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let outerRadius = max(windowCornerRadius, 12.0)
        let arcRadius = max(4.0, outerRadius - edgeInset)
        let center = CGPoint(x: rect.maxX - outerRadius, y: rect.maxY - outerRadius)

        let start = CGPoint(x: center.x - legLength, y: center.y + arcRadius)
        let corner = CGPoint(x: center.x + arcRadius, y: center.y + arcRadius)
        let end = CGPoint(x: center.x + arcRadius, y: center.y - legLength)

        let centerline = CGMutablePath()
        centerline.move(to: start)
        centerline.addArc(tangent1End: corner, tangent2End: end, radius: arcRadius)
        centerline.addLine(to: end)

        let stroked = centerline.copy(
            strokingWithWidth: thickness,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return Path(stroked)
    }
}

/// Liquid Glass corner resize grabber rendered in the bottom-right corner of floating multitask windows.
struct LCLiquidGlassResizeCornerView: View {
    let state: LCLiquidGlassResizeHandleState

    var body: some View {
        let shape = LCResizeCornerArcShape(
            windowCornerRadius: state.windowCornerRadius,
            edgeInset: 6.5,
            thickness: state.isResizing ? 5.5 : 4.5,
            legLength: state.isResizing ? 6.5 : 5.0
        )

        shape
            .fill(Color.primary.opacity(state.isResizing ? 0.14 : 0.08))
            .glassEffect(.regular.interactive(), in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(state.isResizing ? 0.72 : 0.48),
                            Color.white.opacity(state.isResizing ? 0.30 : 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(
                color: .black.opacity(state.isResizing ? 0.28 : 0.18),
                radius: state.isResizing ? 4 : 2.5,
                x: 0,
                y: 1
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(state.isResizing ? 1.05 : 1.0, anchor: .bottomTrailing)
            .animation(.spring(response: 0.24, dampingFraction: 0.74), value: state.isResizing)
    }
}

/// UIKit bridge view embedding `LCLiquidGlassResizeCornerView` inside `ResizeHandleView`.
@MainActor
@objcMembers
final class LCLiquidGlassResizeHandleHostingView: UIView {
    private let state: LCLiquidGlassResizeHandleState
    private let hostingController: UIHostingController<LCLiquidGlassResizeCornerView>

    override init(frame: CGRect) {
        let initialState = LCLiquidGlassResizeHandleState()
        self.state = initialState
        self.hostingController = UIHostingController(rootView: LCLiquidGlassResizeCornerView(state: initialState))
        super.init(frame: frame)
        configureHostingView()
    }

    required init?(coder: NSCoder) {
        let initialState = LCLiquidGlassResizeHandleState()
        self.state = initialState
        self.hostingController = UIHostingController(rootView: LCLiquidGlassResizeCornerView(state: initialState))
        super.init(coder: coder)
        configureHostingView()
    }

    private func configureHostingView() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = false

        hostingController.safeAreaRegions = []
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        hostingController.view.isUserInteractionEnabled = false
        hostingController.view.clipsToBounds = false
        hostingController.view.frame = bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(hostingController.view)
    }

    @objc func setResizing(_ resizing: Bool) {
        state.isResizing = resizing
    }

    @objc func setWindowCornerRadius(_ radius: CGFloat) {
        state.windowCornerRadius = radius
    }
}
