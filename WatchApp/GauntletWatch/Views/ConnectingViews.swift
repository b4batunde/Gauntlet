import Foundation
import SwiftUI

/// Not connected yet: shows what the transport is doing and what the wearer should do.
struct SearchingView: View {
    let status: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        VStack(spacing: 6) {
            RadarView(color: Palette.cyan, animated: !dim)
                .frame(width: 58, height: 58)
            Text(status)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(dim ? Palette.textDim : Color.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            Text(model.isSimulated ? "Run Gauntlet on this Mac" : "Open Gauntlet on your Mac")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// First-time pairing: the same code is on the Mac, where the user confirms it.
struct PairingCodeView: View {
    let code: String
    let macName: String
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        VStack(spacing: 4) {
            CapsLabel(text: "PAIRING CODE", color: dim ? Palette.textDim : Palette.cyan)
            Text(code)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text("Confirm this code on \(macName)")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pairing was declined or could not be verified.
struct RejectedView: View {
    let reason: String
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Palette.red)
                Text(reason)
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ActionButton(title: "Retry", symbol: "arrow.clockwise", color: Palette.cyan) {
                    model.retry()
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

/// The user ended the session. Nothing is streaming and nothing keeps the watch awake.
struct EndedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Palette.violet)
            Text("Session ended")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ActionButton(title: "Start", symbol: "play.fill", color: Palette.green) {
                model.startSession()
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
