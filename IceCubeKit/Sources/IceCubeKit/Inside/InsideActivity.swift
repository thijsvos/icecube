// InsideActivity.swift — how hard the cooling schematic should be working, given who is looking at it.

import Foundation

/// What the Inside window should be doing right now.
///
/// **Written after `occlusionState` turned out not to work.** The first attempt
/// paused the drawing when AppKit reported the window as occluded. The observer
/// attached correctly and the notification fired correctly — and macOS then
/// reported `visible=true` the entire time the window sat underneath a
/// full-screen window of another app. `NSWindow.occlusionState` only drops
/// `.visible` when the system is *confident* the window is entirely behind
/// opaque content, and with vibrancy, transparency and multiple displays around
/// it frequently is not. Measured: 25.9 % CPU covered, 25.9 % CPU uncovered.
///
/// So the signals here are ones that are actually reliable — whether the window
/// is on screen at all, and whether this app is the one being used.
///
/// The middle case is the interesting one. A monitoring window is often left
/// open beside something else, so freezing it outright would break the reason
/// it exists. Instead the *readings* keep updating at the poll rate while the
/// *motion* stops: the temperatures stay live, and the thirty-times-a-second
/// redraw — which is the entire cost, and which nobody is watching — does not
/// happen.
public enum InsideActivity: String, Sendable, Equatable, CaseIterable {
    /// Minimised, or the window is closed. Nothing to draw.
    case hidden
    /// On screen, but another app is frontmost.
    case background
    /// This app is frontmost.
    case foreground

    /// The redraw rate, or `nil` to stop entirely.
    ///
    /// `background` is one frame a second because that is the rate the readings
    /// arrive at — drawing faster than the data changes buys nothing at all.
    public var framesPerSecond: Double? {
        switch self {
        case .hidden: nil
        case .background: 1
        case .foreground: FanRotation.frameRate
        }
    }

    /// Whether the blades and airflow should advance.
    ///
    /// False in the background, and not only to save work: at one frame a
    /// second an integrated phase advances a whole turn per frame, so motion
    /// there would not read as motion — it would read as the stutter this
    /// window has already been fixed for once.
    public var animatesMotion: Bool {
        self == .foreground
    }

    /// Chooses the state from what can actually be observed.
    ///
    /// - Parameters:
    ///   - onScreen: the window exists and is not minimised.
    ///   - appActive: this app is frontmost.
    public static func current(onScreen: Bool, appActive: Bool) -> InsideActivity {
        guard onScreen else { return .hidden }
        return appActive ? .foreground : .background
    }
}
