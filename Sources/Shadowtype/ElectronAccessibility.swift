// ElectronAccessibility — force lazy Chromium/Electron AX trees to materialize (PRD R2 hosts).
// Electron/Chromium only build their accessibility tree when assistive technology is detected, so
// without a nudge our text-marker reads (AXTextProbe) return nothing in VS Code / Cursor / Windsurf /
// Slack / Discord and Chromium browsers (Arc, Dia). Setting the PRIVATE `AXManualAccessibility`
// attribute on the app element is the documented third-party way to trigger that tree, so the user
// doesn't have to run VoiceOver. Native Cocoa apps don't implement the attribute and return
// kAXErrorAttributeUnsupported — a harmless no-op — so we attempt it GENERICALLY per app rather than
// maintain a bundle-id allowlist (this also covers Electron apps we've never heard of).
//
// We set AXManualAccessibility on every app and NOT AXEnhancedUserInterface: the latter is the
// broad "assistive tech is active" flag some apps respond to by reflowing their UI, which we don't
// want to provoke. Manual-accessibility is the narrow, Electron-specific switch. The one exception is
// the opt-in fallback below, for Chromium apps that ignore AXManualAccessibility.
//
// The attribute is NOT universal among Chromium hosts, which is why the write's result is recorded
// rather than discarded (issue #8). `AXManualAccessibility` is implemented by the stock
// `Electron Framework` that Slack / VS Code / Discord / Obsidian / Linear ship, but NOT by
// Chrome-style Chromium builds — Google Chrome doesn't have it (hence the
// `--force-renderer-accessibility` launch hint we show for Arc/Dia), and neither does the OpenAI
// Codex/ChatGPT desktop app, which ships its own rebranded `Codex Framework`. On such a host every
// read in EditContextTracker.readTextAroundCaret returns nil forever and completions go silent with
// no explanation, so the per-pid verdict below is surfaced in the prefix-miss diagnostic to tell
// "this host refuses to expose an AX tree" apart from the other ways a read can fail.
//
// Idempotent + cheap: AXManualAccessibility is attempted once per pid (an app switch is a single AX
// write). The opt-in AXEnhancedUserInterface fallback is the exception: it is switched on when the
// app comes to the front and off again shortly after it leaves (see `applicationDidActivate`).
import AppKit
import ApplicationServices

final class ElectronAccessibility {
    /// What one AXManualAccessibility write told us about a host.
    enum Support: Equatable {
        /// The host accepted the write: a stock-Electron app whose AX tree is now materialized.
        case supported
        /// The host rejected `AXManualAccessibility` but is a Chromium app that accepted the broader
        /// `AXEnhancedUserInterface` flag instead (e.g. the Claude desktop app), so its AX tree is built
        /// while the app is in front. Only ever tried for non-browser Chromium hosts, and only after the
        /// user opted in.
        case enhancedFallback
        /// The host does not implement the attribute. Expected and harmless for native Cocoa apps
        /// (they never needed it); for a Chromium-backed host it means we have no way to wake its
        /// AX tree and text reads there will keep returning nil.
        case unsupported
        /// A transient AX failure (app launching, not yet accepting AX messages, API disabled).
        /// Says nothing about the host, so it never overwrites a definite verdict.
        case unknown

        /// Short, stable token for the diagnostic log.
        var diagLabel: String {
            switch self {
            case .supported:   return "supported"
            case .enhancedFallback: return "enhanced-fallback"
            case .unsupported: return "unsupported"
            case .unknown:     return "unknown"
            }
        }
    }

    /// Pure (testable): what one `AXUIElementSetAttributeValue` result says about the host. Only the
    /// two definite outcomes are claimed — a host that genuinely answered (`.success`) and one that
    /// genuinely refused the attribute (`.attributeUnsupported`). Every other AXError is
    /// environmental (the app is still launching, AX is off, the element went stale) and must stay
    /// `.unknown` so a mid-launch app is never libelled as unreadable.
    static func classify(_ error: AXError) -> Support {
        switch error {
        case .success:              return .supported
        case .attributeUnsupported: return .unsupported
        default:                    return .unknown
        }
    }

    /// Pure (testable): what one `AXEnhancedUserInterface` write result says. Unlike the manual attribute
    /// this write is retried, so "the host did not answer" must stay distinct from "the host said no".
    enum EnhancedOutcome: Equatable {
        /// The host accepted the flag: its AX tree is being built.
        case on
        /// The reply timed out (`cannotComplete`). The flag may or may not have been applied, so it is
        /// treated as possibly on (we owe it a `false`) and as not yet working (we try again).
        case maybeOn
        /// The host does not implement the attribute. Definite: never retried.
        case refused
        /// Anything else (app busy, element stale, API disabled): says nothing, try again later.
        case transient
    }

    static func classifyEnhanced(_ error: AXError) -> EnhancedOutcome {
        switch error {
        case .success:              return .on
        case .cannotComplete:       return .maybeOn
        case .attributeUnsupported: return .refused
        default:                    return .transient
        }
    }

    /// The AX write itself, injectable so the bookkeeping above is testable without a live app.
    typealias AttributeWriter = (pid_t) -> AXError
    /// The AXEnhancedUserInterface write: (pid, on). Injectable like `AttributeWriter`.
    typealias EnhancedWriter = (pid_t, Bool) -> AXError
    /// Runs a block after a delay. Injectable so the delayed switch-off is testable without waiting.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let write: AttributeWriter
    // Fallback for Chromium hosts that do not implement AXManualAccessibility (the Claude desktop app,
    // like the Codex app). Gates, all of which must hold: the user opted in (`enhancedEnabled`, off by
    // default), Shadowtype is on for that app (`isAllowed`), the host is a non-browser Chromium app
    // (`isChromiumHost`), and AXManualAccessibility was rejected as unsupported. The flag is only ON
    // while that app is in front: it is switched back off a few seconds after the app deactivates, when
    // the user turns the setting off, and for every app when Shadowtype quits (`revertAll`), because a
    // full accessibility tree costs the host CPU and the flag can upset window animations and window
    // managers.
    private let enhancedWrite: EnhancedWriter
    private let enhancedEnabled: () -> Bool
    private let isChromiumHost: (pid_t) -> Bool
    private let schedule: Scheduler
    private let revertDelay: TimeInterval
    /// Set by the owner: false while Shadowtype is paused or the app is disabled in App rules.
    var isAllowed: (pid_t) -> Bool = { _ in true }

    /// Consecutive failed fallback writes allowed per activation before we stop asking a busy host.
    static let maxEnhancedFailures = 3

    // Pids whose flag we have set, or tried to set and cannot be sure about; each one is owed a `false`.
    private var enhancedActive: Set<pid_t> = []
    // Hosts that said the attribute does not exist: never asked again.
    private var enhancedRefused: Set<pid_t> = []
    // Failed writes since the host last came to the front.
    private var enhancedFailures: [pid_t: Int] = [:]
    // The Chromium test lists a directory, so ask once per pid.
    private var chromiumHostByPid: [pid_t: Bool] = [:]
    // Deactivated pids waiting for their delayed switch-off; the value says which deactivation owns it,
    // so a quick return (or a newer deactivation) makes the older timer do nothing.
    private var pendingRevert: [pid_t: UInt64] = [:]
    private var revertGeneration: UInt64 = 0
    // Set by a fallback write whose outcome can still lead to a tree (on, timed out, or a passing failure).
    private var flagWriteMayHelp = false

    // Pids already attempted. A relaunch gets a fresh pid, so an entry never goes stale for a live
    // process; `applicationDidTerminate` drops the entries of a process that quit (pids are reused).
    private var forced: Set<pid_t> = []
    // Best verdict seen per pid. Same bound as `forced`.
    private var supportByPid: [pid_t: Support] = [:]

    init(write: @escaping AttributeWriter = ElectronAccessibility.liveWrite,
         enhancedWrite: @escaping EnhancedWriter = ElectronAccessibility.liveEnhancedWrite,
         enhancedEnabled: @escaping () -> Bool = ElectronAccessibility.liveEnhancedEnabled,
         isChromiumHost: @escaping (pid_t) -> Bool = ElectronAccessibility.liveIsChromiumHost,
         revertDelay: TimeInterval = ElectronAccessibility.defaultRevertDelay,
         schedule: @escaping Scheduler = ElectronAccessibility.liveSchedule) {
        self.write = write
        self.enhancedWrite = enhancedWrite
        self.enhancedEnabled = enhancedEnabled
        self.isChromiumHost = isChromiumHost
        self.revertDelay = revertDelay
        self.schedule = schedule
    }

    /// How long an app may stay out of front before its flag is switched off again. Cmd-Tab back and
    /// forth costs nothing; an app left alone stops paying for its tree.
    static let defaultRevertDelay: TimeInterval = 5

    static func liveSchedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    /// Cap on how long one fallback write may block the main thread (AX calls wait ~6 s by default, and the
    /// app losing focus is often the busy one).
    static let enhancedMessagingTimeout: Float = 0.25

    /// The broader flag: Chromium turns its AX tree on when it is set. Fallback only (see above).
    static func liveEnhancedWrite(pid: pid_t, on: Bool) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, enhancedMessagingTimeout)
        return AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Settings ▸ Apps ▸ "Enable accessibility for Chromium apps". Off unless the user turns it on.
    static let enhancedDefaultsKey = "shadowtype.chromiumAccessibilityFallback"
    static func liveEnhancedEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: enhancedDefaultsKey)
    }

    /// True for a non-browser Chromium/Electron app: its bundle ships a "… Helper (Renderer).app".
    /// Browsers (Chrome, Arc, Dia, …) are excluded: they have their own priming and launch-flag path.
    static func liveIsChromiumHost(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleURL = app.bundleURL else { return false }
        if let id = app.bundleIdentifier, ActivationPolicy.isBrowser(bundleId: id) { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return items.contains { $0.hasSuffix("Helper (Renderer).app") }
    }

    /// The real AX write: set the private attribute on the app element and hand back the raw result.
    static func liveWrite(pid: pid_t) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        return AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // Attempt to enable manual accessibility on `pid` once. Returns true if this call performed the
    // first attempt for that pid, false if it was already attempted. The AX write itself is
    // best-effort (unsupported on native apps), so the return reflects bookkeeping, not AX success —
    // ask `support(pid:)` for that.
    @discardableResult
    func forceIfNeeded(pid: pid_t) -> Bool {
        guard pid > 0, !forced.contains(pid) else { return false }
        forced.insert(pid)
        apply(pid: pid)
        return true
    }

    // Apply unconditionally — same AX write, but no "first attempt" bookkeeping. Use on every browser
    // focus so that a Chrome AX tree that wasn't built when we first set the attribute (cold start,
    // tab not yet selected, web area not yet rendered) gets re-primed. Idempotent: setting it again on
    // an already-primed tree is a no-op for Chrome but harmless. Cheap (one AX message).
    @discardableResult
    func apply(pid: pid_t) -> Support {
        guard pid > 0 else { return .unknown }
        let observed = Self.classify(write(pid))
        // A definite verdict is sticky: a later transient failure (app busy, element stale) must not
        // downgrade a host we already know answers — or refuses — the attribute. A host already
        // switched on through the fallback stays `.enhancedFallback` for the same reason: its manual
        // write keeps coming back `.unsupported`.
        if supportByPid[pid] == .enhancedFallback, observed == .unsupported { return .enhancedFallback }
        if observed != .unknown || supportByPid[pid] == nil {
            supportByPid[pid] = observed
        }
        if supportByPid[pid] == .unsupported { enableEnhancedIfEligible(pid: pid) }
        return supportByPid[pid] ?? observed
    }

    /// `pid` became the active app. First contact is the normal attempt (which takes the fallback itself
    /// when the host rejects the manual attribute). After that, the fallback is retried whenever it is
    /// not working yet: the user opted in after we first saw the app, the flag was switched off after the
    /// app deactivated, or an earlier write failed for a passing reason. Returns true when a fallback
    /// write was made that can still give a tree, so the caller knows the host is still building it and
    /// can look again soon.
    @discardableResult
    func applicationDidActivate(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        pendingRevert[pid] = nil                       // back before the delayed switch-off: keep the flag on
        flagWriteMayHelp = false
        if !forceIfNeeded(pid: pid), supportByPid[pid] == .unsupported || supportByPid[pid] == .enhancedFallback {
            enableEnhancedIfEligible(pid: pid)
        }
        return flagWriteMayHelp
    }

    /// `pid` lost focus. A flag we hold is switched off after `revertDelay`, unless the app comes back first.
    func applicationDidDeactivate(pid: pid_t) {
        enhancedFailures[pid] = nil
        guard enhancedActive.contains(pid) else { return }
        revertGeneration &+= 1
        let generation = revertGeneration
        pendingRevert[pid] = generation
        schedule(revertDelay) { [weak self] in
            guard let self, self.pendingRevert[pid] == generation else { return }
            self.pendingRevert[pid] = nil
            self.switchOff(pid: pid)
        }
    }

    /// `pid` quit. Forget everything about it: pids are reused, and a new process must not inherit the old
    /// one's verdict or flag. Nothing to switch off, the process is gone.
    func applicationDidTerminate(pid: pid_t) {
        forced.remove(pid)
        supportByPid[pid] = nil
        enhancedActive.remove(pid)
        enhancedRefused.remove(pid)
        enhancedFailures[pid] = nil
        chromiumHostByPid[pid] = nil
        pendingRevert[pid] = nil
    }

    /// Leave no app switched on: Shadowtype is quitting or stopping, or the user turned the setting off.
    /// A host that needed the fallback goes back to `.unsupported`, which is the truth while the flag is off
    /// and lets it be tried again if the setting comes back on.
    func revertAll() {
        for pid in enhancedActive { _ = enhancedWrite(pid, false) }
        enhancedActive.removeAll()
        pendingRevert.removeAll()
        enhancedFailures.removeAll()
        for (pid, verdict) in supportByPid where verdict == .enhancedFallback { supportByPid[pid] = .unsupported }
    }

    /// The opt-in setting changed. Turning it off switches every app off at once.
    func enhancedSettingDidChange() {
        if !enhancedEnabled() { revertAll() }
    }

    /// True while Shadowtype holds AXEnhancedUserInterface on for `pid`. Test seam.
    func isEnhancedActive(pid: pid_t) -> Bool { enhancedActive.contains(pid) }

    // The flag is on and the host accepted it. A timed-out write is owed a `false` but is not this.
    private func isEnhancedConfirmed(pid: pid_t) -> Bool {
        enhancedActive.contains(pid) && supportByPid[pid] == .enhancedFallback
    }

    private func hostIsChromium(pid: pid_t) -> Bool {
        if let known = chromiumHostByPid[pid] { return known }
        let isHost = isChromiumHost(pid)
        chromiumHostByPid[pid] = isHost
        return isHost
    }

    private func switchOff(pid: pid_t) {
        guard enhancedActive.remove(pid) != nil else { return }
        _ = enhancedWrite(pid, false)
    }

    /// Switch the broader flag on for `pid` if every gate holds and it is not already working.
    private func enableEnhancedIfEligible(pid: pid_t) {
        guard !isEnhancedConfirmed(pid: pid), !enhancedRefused.contains(pid),
              (enhancedFailures[pid] ?? 0) < Self.maxEnhancedFailures,
              enhancedEnabled(), isAllowed(pid), hostIsChromium(pid: pid) else { return }
        switch Self.classifyEnhanced(enhancedWrite(pid, true)) {
        case .on:
            flagWriteMayHelp = true
            enhancedActive.insert(pid)
            enhancedFailures[pid] = nil
            supportByPid[pid] = .enhancedFallback
        case .maybeOn:
            flagWriteMayHelp = true
            enhancedActive.insert(pid)                  // it may have taken effect: we still owe it a `false`
            enhancedFailures[pid, default: 0] += 1
        case .refused:
            enhancedRefused.insert(pid)
        case .transient:
            flagWriteMayHelp = true
            enhancedFailures[pid, default: 0] += 1
        }
    }

    /// The best verdict recorded for `pid`, or `.unknown` if it was never attempted. Read by the
    /// prefix-miss diagnostic so an unreadable Chromium host is identifiable from a log alone.
    func support(pid: pid_t) -> Support {
        supportByPid[pid] ?? .unknown
    }
}
