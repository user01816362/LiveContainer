//
//  LCDebugTelemetryBar.swift
//  LiveContainerSwiftUI
//
//  Isolated 1Hz process telemetry strip reading only LCDebugTelemetryStore so
//  high-frequency FPS/CPU/RAM ticks do not invalidate other Debug Studio views.
//

import SwiftUI

struct LCDebugTelemetryBar: View {
    let telemetryStore: LCDebugTelemetryStore
    let isConnected: Bool
    let onCopyLANURL: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if telemetryStore.pid > 0 {
                    LCDebugTelemetryBadge(text: "PID \(telemetryStore.pid)", tint: .secondary)
                }
                LCDebugTelemetryBadge(
                    text: "\(String(format: "%.0f", telemetryStore.cpuPercent))% CPU",
                    tint: telemetryStore.cpuPercent > 85 ? .orange : .secondary
                )
                LCDebugTelemetryBadge(
                    text: "\(String(format: "%.0f", telemetryStore.memoryMB)) MB",
                    tint: .secondary
                )
                LCDebugTelemetryBadge(
                    text: "\(telemetryStore.fps) FPS",
                    tint: (telemetryStore.fps > 0 && telemetryStore.fps < 45) ? .yellow : .mint
                )
                LCDebugTelemetryBadge(
                    text: telemetryStore.isJIT ? "JIT ON" : "JIT-Less",
                    tint: telemetryStore.isJIT ? .green : .cyan
                )

                if let lanURL = telemetryStore.macLANURLString {
                    Button {
                        onCopyLANURL(lanURL)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("LAN \(telemetryStore.lanIP):\(telemetryStore.lanPort)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.14), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }

                if telemetryStore.isXRayEnabled {
                    LCDebugTelemetryBadge(text: "X-Ray", tint: .orange)
                }
                if telemetryStore.isTapInspectEnabled {
                    LCDebugTelemetryBadge(text: "Tap Inspect", tint: .cyan)
                }
                if telemetryStore.networkPaused {
                    LCDebugTelemetryBadge(text: "Net Paused", tint: .red)
                }
                if !isConnected {
                    LCDebugTelemetryBadge(text: "Offline", tint: .orange)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct LCDebugTelemetryBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint == .secondary ? Color.white.opacity(0.88) : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (tint == .secondary ? Color.white.opacity(0.08) : tint.opacity(0.14)),
                in: .capsule
            )
    }
}
