//
//  LCLiquidGlassResizeHandleView.swift
//  LiveContainer
//

import Observation
import SwiftUI
import UIKit

/// Shared observable state driving the outer Liquid Glass corner resize grabber.
@MainActor
@Observable
final class LCLiquidGlassResizeHandleState {
    var isResizing: Bool = false
    var windowCornerRadius: CGFloat = 18.0
}

/// Concentric curved arc pill positioned *outside* the bottom-right corner of a floating
/// multitask window (`48×48` handle view protruding `14pt` past the window frame).
struct LCOuterResizeCornerArcShape: Shape {
    var windowCornerRadius: CGFloat
    var outset: CGFloat = 14.0
    var gap: CGFloat
    var thickness: CGFloat
    var legLength: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let cornerX = rect.maxX - outset
        let cornerY = rect.maxY - outset
        let outerRadius = max(windowCornerRadius, 12.0)
        let center = CGPoint(x: cornerX - outerRadius, y: cornerY - outerRadius)
        let arcRadius = outerRadius + gap + thickness * 0.5

        let start = CGPoint(x: center.x - legLength, y: center.y + arcRadius)
        let tangentCorner = CGPoint(x: center.x + arcRadius, y: center.y + arcRadius)
        let end = CGPoint(x: center.x + arcRadius, y: center.y - legLength)

        let centerline = CGMutablePath()
        centerline.move(to: start)
        centerline.addArc(tangent1End: tangentCorner, tangent2End: end, radius: arcRadius)
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

/// Native iOS Liquid Glass corner resize grabber: subtle & reduced at rest outside the
/// window corner, expanding and brightening smoothly on pointer hover or active drag.
struct LCLiquidGlassResizeCornerView: View {
    let state: LCLiquidGlassResizeHandleState

    var body: some View {
        let arcShape = LCOuterResizeCornerArcShape(
            windowCornerRadius: state.windowCornerRadius,
            outset: 14.0,
            gap: state.isResizing ? 4.0 : 3.5,
            thickness: state.isResizing ? 6.0 : 4.5,
            legLength: state.isResizing ? 7.0 : 5.0
        )

        // Apply `.glassEffect` on a standard convex RoundedRectangle first to avoid iOS 26
        // concave-shape fallback artifacts, then clip to the concentric outer corner arc.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                arcShape.fill(Color.white.opacity(state.isResizing ? 0.24 : 0.12))
            }
            .clipShape(arcShape)
            .overlay {
                arcShape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(state.isResizing ? 0.85 : 0.55),
                            Color.white.opacity(state.isResizing ? 0.35 : 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .opacity(state.isResizing ? 1.0 : 0.72)
            .shadow(
                color: .black.opacity(state.isResizing ? 0.32 : 0.20),
                radius: state.isResizing ? 5 : 3,
                x: 0,
                y: 1
            )
            .animation(.spring(response: 0.22, dampingFraction: 0.74), value: state.isResizing)
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
