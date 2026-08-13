import Foundation

/// "You are looking at a canvas that is not yours" — the state behind the
/// take-over banner.
///
/// The trigger is the SYMPTOM, not the mode: this device's grid differs from
/// the grid the session is rendered at, whatever `window-size` happens to be.
/// Gating on `.thisDevice` (the one mode with a real owner) would have missed
/// the common case, because the default `.tracking` has no owner to name and is
/// exactly where "this doesn't fit my screen and I don't know why" comes from.
///
/// The copy therefore has to say two different things with one shape: under
/// `.thisDevice` there is a device to name and the tap dispossesses it; under
/// the client-derived policies nobody claimed anything, so the tap just claims
/// it — and asking to confirm would be friction with no one on the other end.
public struct SessionSizeMismatch: Equatable, Sendable {
    public let mode: TerminalSizingMode
    /// The owning device's label, only ever non-nil under `.thisDevice` — the
    /// other two policies derive the size from the attached clients, so there
    /// is nobody to name.
    public let owner: String?
    /// The grid the session is actually drawn at (the tmux window's size).
    public let sessionCols: Int
    public let sessionRows: Int
    /// The grid THIS device fits.
    public let deviceCols: Int
    public let deviceRows: Int

    public init(mode: TerminalSizingMode, owner: String?,
                sessionCols: Int, sessionRows: Int,
                deviceCols: Int, deviceRows: Int) {
        self.mode = mode
        self.owner = owner
        self.sessionCols = sessionCols
        self.sessionRows = sessionRows
        self.deviceCols = deviceCols
        self.deviceRows = deviceRows
    }

    /// Who is deciding the size. Each line uses the same vocabulary as the
    /// mode's own `explanation`, so the banner and the Session Size menu
    /// describe one thing rather than two.
    public var title: String {
        switch mode {
        case .thisDevice:
            // No owner recorded is the pre-ownership "freeze" left on a session
            // by an older build: `manual` with nobody re-asserting a size.
            guard let owner else { return "The session size is pinned" }
            return "Sized by \(owner)"
        case .tracking:
            return "Sized by the device used most recently"
        case .smallest:
            return "Sized to the smallest attached device"
        }
    }

    /// The two numbers that explain what the user is looking at.
    public var detail: String {
        "\(sessionCols)×\(sessionRows) · this device fits \(deviceCols)×\(deviceRows)"
    }

    /// The same two numbers where there is only room for one line — the arrow
    /// is what the tap would do, not what happened.
    public var compactDetail: String {
        "\(sessionCols)×\(sessionRows) → \(deviceCols)×\(deviceRows)"
    }

    /// What tapping does — the SAME words in every mode, and the same words the
    /// Session Size menu uses for the state it puts you in.
    ///
    /// This deliberately does not vary ("Take Over" when dispossessing someone,
    /// the mode name otherwise). A control that is read in a glance should not
    /// make the reader work out which of two phrasings applies before knowing
    /// what the click does, and the distinction it was drawing — whether another
    /// device loses control — is carried by the confirmation sheet, which is
    /// where it actually matters.
    public var actionTitle: String { TerminalSizingMode.thisDevice.title }

    /// Confirm ONLY when a named device is being dispossessed. Under the
    /// client-derived policies nobody loses control they explicitly claimed.
    public var needsConfirmation: Bool { owner != nil }

    public var confirmTitle: String {
        guard let owner else { return "Size to this device?" }
        return "Take the size over from \(owner)?"
    }

    /// Says what will happen, on both ends — the other device losing control is
    /// the part that is not visible from here.
    public var confirmMessage: String {
        let other = owner ?? "The other device"
        return "\(other) stops setting the session size. The session resizes to this device's \(deviceCols)×\(deviceRows) and stays there until another device takes it over."
    }

    /// One line for VoiceOver and for anywhere too narrow for two.
    public var summary: String { "\(title). \(detail)." }
}
