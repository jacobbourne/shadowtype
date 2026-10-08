// ElectronAccessibility — per-pid "force once" bookkeeping. The AX side effect is live-only, but the
// idempotence (one attempt per pid, re-armed by reset) is the contract the focus path relies on to
// stay cheap, and that is pure + testable.
import XCTest
import ApplicationServices
@testable import Shadowtype

final class ElectronAccessibilityTests: XCTestCase {
    func testForcesOncePerPid() {
        let ea = ElectronAccessibility()
        XCTAssertTrue(ea.forceIfNeeded(pid: 4242))   // first attempt
        XCTAssertFalse(ea.forceIfNeeded(pid: 4242))  // already attempted
        XCTAssertFalse(ea.forceIfNeeded(pid: 4242))
    }

    func testDistinctPidsEachForcedOnce() {
        let ea = ElectronAccessibility()
        XCTAssertTrue(ea.forceIfNeeded(pid: 1))
        XCTAssertTrue(ea.forceIfNeeded(pid: 2))
        XCTAssertFalse(ea.forceIfNeeded(pid: 1))
    }

    func testInvalidPidIsNotForced() {
        let ea = ElectronAccessibility()
        XCTAssertFalse(ea.forceIfNeeded(pid: 0))
        XCTAssertFalse(ea.forceIfNeeded(pid: -1))
    }
}

// The AXManualAccessibility verdict (issue #8). Stock-Electron hosts (Slack, VS Code, Discord,
// Obsidian, Linear) implement the private attribute; Chrome-style Chromium builds — Google Chrome,
// and the OpenAI Codex/ChatGPT desktop app with its rebranded `Codex Framework` — do not, so the
// write is silently swallowed and their AX tree is never materialized. Recording the result is what
// lets a prefix-miss log tell those two cases apart.
final class ElectronAccessibilitySupportTests: XCTestCase {
    /// An `ElectronAccessibility` whose AX write is stubbed, plus the pids it was asked to write to.
    private func makeStub(
        _ result: @escaping (pid_t) -> AXError
    ) -> (ElectronAccessibility, () -> [pid_t]) {
        var writes: [pid_t] = []
        let ea = ElectronAccessibility(write: { pid in
            writes.append(pid)
            return result(pid)
        })
        return (ea, { writes })
    }

    // MARK: - classify (pure)

    func testSuccessMeansHostImplementsTheAttribute() {
        XCTAssertEqual(ElectronAccessibility.classify(.success), .supported)
    }

    func testAttributeUnsupportedIsTheDefiniteRefusal() {
        XCTAssertEqual(
            ElectronAccessibility.classify(.attributeUnsupported), .unsupported)
    }

    func testTransientErrorsNeverClaimAVerdict() {
        // A launching app, a stale element or AX being off says nothing about the host — claiming
        // `.unsupported` here would libel an app that works fine a moment later.
        for error: AXError in [.cannotComplete, .invalidUIElement, .apiDisabled,
                               .notImplemented, .failure, .illegalArgument] {
            XCTAssertEqual(ElectronAccessibility.classify(error), .unknown,
                           "\(error) must not be read as a verdict about the host")
        }
    }

    // MARK: - recording

    func testStockElectronHostIsRecordedAsSupported() {
        let (ea, writes) = makeStub { _ in .success }
        XCTAssertTrue(ea.forceIfNeeded(pid: 501))

        XCTAssertEqual(ea.support(pid: 501), .supported)
        XCTAssertEqual(writes(), [501])
    }

    func testChromeStyleHostIsRecordedAsUnsupported() {
        // The issue-#8 shape: the write is accepted by the AX layer but the app implements no
        // handler, so its AX tree is never built and every later text read returns nil.
        let (ea, _) = makeStub { _ in .attributeUnsupported }
        XCTAssertTrue(ea.forceIfNeeded(pid: 909))

        XCTAssertEqual(ea.support(pid: 909), .unsupported)
        XCTAssertEqual(ea.support(pid: 909).diagLabel, "unsupported")
    }

    func testNeverAttemptedPidIsUnknown() {
        let (ea, writes) = makeStub { _ in .success }
        XCTAssertEqual(ea.support(pid: 777), .unknown)
        XCTAssertEqual(writes(), [], "asking for a verdict must not trigger an AX write")
    }

    func testInvalidPidIsNeverWrittenToAndStaysUnknown() {
        let (ea, writes) = makeStub { _ in .success }
        XCTAssertEqual(ea.apply(pid: 0), .unknown)
        XCTAssertEqual(ea.apply(pid: -3), .unknown)
        XCTAssertEqual(writes(), [])
    }

    func testDefiniteVerdictSurvivesALaterTransientFailure() {
        // The browser re-prime path calls apply() repeatedly; one `cannotComplete` while the app is
        // busy must not erase the fact that it answered the attribute earlier.
        var next: AXError = .success
        let (ea, _) = makeStub { _ in next }
        XCTAssertEqual(ea.apply(pid: 42), .supported)

        next = .cannotComplete
        XCTAssertEqual(ea.apply(pid: 42), .supported)
        XCTAssertEqual(ea.support(pid: 42), .supported)
    }

    func testTransientVerdictIsUpgradedOnceTheHostAnswers() {
        // Mirror image: an app probed mid-launch records `.unknown`, and the next probe must be able
        // to settle it either way rather than staying stuck.
        var next: AXError = .cannotComplete
        let (ea, _) = makeStub { _ in next }
        XCTAssertEqual(ea.apply(pid: 7), .unknown)

        next = .attributeUnsupported
        XCTAssertEqual(ea.apply(pid: 7), .unsupported)
        XCTAssertEqual(ea.support(pid: 7), .unsupported)
    }

    func testVerdictsAreKeyedPerPid() {
        let (ea, _) = makeStub { pid in pid == 1 ? .success : .attributeUnsupported }
        ea.forceIfNeeded(pid: 1)
        ea.forceIfNeeded(pid: 2)

        XCTAssertEqual(ea.support(pid: 1), .supported)
        XCTAssertEqual(ea.support(pid: 2), .unsupported)
    }

    func testForceIfNeededStillWritesExactlyOncePerPid() {
        // The verdict bookkeeping must not disturb the per-pid write budget the focus path relies on.
        let (ea, writes) = makeStub { _ in .success }
        ea.forceIfNeeded(pid: 55)
        ea.forceIfNeeded(pid: 55)
        ea.forceIfNeeded(pid: 55)

        XCTAssertEqual(writes(), [55])
    }

    // MARK: - AXEnhancedUserInterface fallback (Claude desktop app, Codex app: issue #8)

    /// Like `makeStub`, with the fallback's collaborators injected: the AXEnhancedUserInterface writer, the
    /// user's opt-in, the "is this a non-browser Chromium host" test, the "Shadowtype is on for this app"
    /// gate, and a scheduler that holds the delayed switch-off until the test runs it.
    private final class FallbackStub {
        var enhancedWrites: [(pid: pid_t, on: Bool)] = []
        var manualWrites: [pid_t] = []
        var chromiumAsks: [pid_t] = []
        var scheduled: [(delay: TimeInterval, block: () -> Void)] = []
        var manual: (pid_t) -> AXError = { _ in .attributeUnsupported }
        var enhanced: (pid_t, Bool) -> AXError = { _, _ in .success }
        var enabled = true
        var allowed = true
        var chromium: (pid_t) -> Bool = { _ in true }
        lazy var ea: ElectronAccessibility = {
            let ea = ElectronAccessibility(
                write: { [unowned self] pid in self.manualWrites.append(pid); return self.manual(pid) },
                enhancedWrite: { [unowned self] pid, on in
                    self.enhancedWrites.append((pid, on)); return self.enhanced(pid, on) },
                enhancedEnabled: { [unowned self] in self.enabled },
                isChromiumHost: { [unowned self] pid in self.chromiumAsks.append(pid); return self.chromium(pid) },
                revertDelay: 5,
                schedule: { [unowned self] delay, block in self.scheduled.append((delay, block)) })
            ea.isAllowed = { [unowned self] _ in self.allowed }
            return ea
        }()
        /// The last block the scheduler was given, run now (the delay "elapsed").
        func fireLastTimer() { scheduled.last?.block() }
        var onWrites: Int { enhancedWrites.filter { $0.on }.count }
        var offWrites: Int { enhancedWrites.filter { !$0.on }.count }
    }

    // classifyEnhanced (pure)

    func testEnhancedWriteResultsAreSortedIntoOnMaybeRefusedAndTransient() {
        XCTAssertEqual(ElectronAccessibility.classifyEnhanced(.success), .on)
        XCTAssertEqual(ElectronAccessibility.classifyEnhanced(.cannotComplete), .maybeOn,
                       "a timed-out reply may still have been applied")
        XCTAssertEqual(ElectronAccessibility.classifyEnhanced(.attributeUnsupported), .refused)
        for error: AXError in [.apiDisabled, .invalidUIElement, .failure, .illegalArgument, .notImplemented] {
            XCTAssertEqual(ElectronAccessibility.classifyEnhanced(error), .transient, "\(error)")
        }
    }

    // When the fallback is taken

    func testFallbackIsTakenOnlyWhenManualIsUnsupportedAndTheHostIsChromium() {
        let s = FallbackStub()
        XCTAssertEqual(s.ea.apply(pid: 10), .enhancedFallback)
        XCTAssertEqual(s.enhancedWrites.count, 1)
        XCTAssertEqual(s.enhancedWrites.first?.pid, 10)
        XCTAssertEqual(s.enhancedWrites.first?.on, true)
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.ea.support(pid: 10).diagLabel, "enhanced-fallback")
    }

    func testFallbackIsNeverTakenForANativeAppOrABrowser() {
        // `isChromiumHost` is false for native Cocoa apps and for browsers (liveIsChromiumHost excludes them).
        let s = FallbackStub()
        s.chromium = { _ in false }
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported)
        XCTAssertTrue(s.enhancedWrites.isEmpty)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
    }

    func testFallbackIsNeverTakenWhenManualAccessibilityIsSupported() {
        let s = FallbackStub()
        s.manual = { _ in .success }
        XCTAssertEqual(s.ea.apply(pid: 10), .supported)
        XCTAssertTrue(s.enhancedWrites.isEmpty)
        XCTAssertTrue(s.chromiumAsks.isEmpty, "no need to look at the app bundle")
    }

    func testFallbackIsNeverTakenUnlessTheUserOptedIn() {
        let s = FallbackStub()
        s.enabled = false
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported)
        XCTAssertTrue(s.enhancedWrites.isEmpty)
    }

    func testFallbackIsNeverTakenWhileShadowtypeIsPausedOrTheAppIsDisabled() {
        let s = FallbackStub()
        s.allowed = false
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported)
        XCTAssertFalse(s.ea.applicationDidActivate(pid: 10))
        XCTAssertTrue(s.enhancedWrites.isEmpty)

        s.allowed = true                                   // un-paused: the next activation takes it
        XCTAssertTrue(s.ea.applicationDidActivate(pid: 10))
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
    }

    func testEnhancedFallbackVerdictIsStickyAgainstALaterUnsupported() {
        let s = FallbackStub()
        XCTAssertEqual(s.ea.apply(pid: 10), .enhancedFallback)
        // Manual is still unsupported on the next apply(); the verdict must not slide back to .unsupported.
        XCTAssertEqual(s.ea.apply(pid: 10), .enhancedFallback)
        XCTAssertEqual(s.ea.support(pid: 10), .enhancedFallback)
        XCTAssertEqual(s.onWrites, 1, "the flag is already on: no second write")
    }

    func testAHostThatRefusesTheFlagIsNeverAskedAgain() {
        let s = FallbackStub()
        s.enhanced = { _, _ in .attributeUnsupported }
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported)
        XCTAssertFalse(s.ea.applicationDidActivate(pid: 10), "a definite refusal gives no tree to wait for")
        XCTAssertFalse(s.ea.applicationDidActivate(pid: 10))
        XCTAssertEqual(s.onWrites, 1)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
    }

    // Opting in after Shadowtype already met the app (review point 1)

    func testOptingInAfterFirstContactTakesEffectOnTheNextActivation() {
        let s = FallbackStub()
        s.enabled = false
        s.ea.applicationDidActivate(pid: 10)               // Shadowtype sees Claude before the opt-in
        XCTAssertEqual(s.ea.support(pid: 10), .unsupported)
        XCTAssertTrue(s.enhancedWrites.isEmpty)

        s.enabled = true                                   // the user turns it on in Settings, switches back
        XCTAssertTrue(s.ea.applicationDidActivate(pid: 10), "a flag write was made: the caller should look again soon")
        XCTAssertEqual(s.ea.support(pid: 10), .enhancedFallback)
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.manualWrites, [10], "the manual attribute is still asked only once")
    }

    func testANativeAppIsNotInspectedAgainOnEveryActivation() {
        let s = FallbackStub()
        s.chromium = { _ in false }
        for _ in 0..<4 { s.ea.applicationDidActivate(pid: 10) }
        XCTAssertEqual(s.chromiumAsks, [10], "listing the app bundle happens once per process")
    }

    func testTurningTheOptInOffSwitchesEveryAppOffAtOnce() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidActivate(pid: 11)
        s.enabled = false
        s.ea.enhancedSettingDidChange()
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 11))
        XCTAssertEqual(s.enhancedWrites.filter { !$0.on }.map { $0.pid }.sorted(), [10, 11])
        XCTAssertEqual(s.ea.support(pid: 10), .unsupported, "the flag is off, so the verdict says so")

        s.enabled = true                                   // and back on: the next activation takes it again
        XCTAssertTrue(s.ea.applicationDidActivate(pid: 10))
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
    }

    func testTheSettingChangingButStayingOnLeavesEverythingAlone() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        s.ea.enhancedSettingDidChange()
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.offWrites, 0)
    }

    // Switch-off after the app leaves (review point 8, second half)

    func testFlagIsSwitchedOffOnlyAfterTheDelayAndBackOnWhenTheAppReturns() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))

        s.ea.applicationDidDeactivate(pid: 10)
        XCTAssertEqual(s.scheduled.last?.delay, 5)
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10), "still on during the grace period")
        XCTAssertEqual(s.offWrites, 0)

        s.fireLastTimer()                                  // five quiet seconds later
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.enhancedWrites.last?.on, false)

        XCTAssertTrue(s.ea.applicationDidActivate(pid: 10)) // back in front: the host rebuilds its tree
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.enhancedWrites.last?.on, true)
    }

    func testComingBackWithinTheDelayKeepsTheFlagAndWritesNothing() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidDeactivate(pid: 10)
        XCTAssertFalse(s.ea.applicationDidActivate(pid: 10), "already on: no write, nothing to wait for")
        s.fireLastTimer()                                  // the old timer must now do nothing
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.enhancedWrites.count, 1)
    }

    func testAnOlderTimerCannotSwitchOffAnAppThatLeftAgainLater() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidDeactivate(pid: 10)
        let firstTimer = s.scheduled[0].block
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidDeactivate(pid: 10)
        firstTimer()
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10), "the newer deactivation owns the switch-off")
        s.fireLastTimer()
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.offWrites, 1)
    }

    func testDeactivatingAnAppWeNeverTouchedWritesNothingAndSchedulesNothing() {
        let s = FallbackStub()
        s.chromium = { _ in false }
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidDeactivate(pid: 10)
        XCTAssertTrue(s.enhancedWrites.isEmpty)
        XCTAssertTrue(s.scheduled.isEmpty)
    }

    func testRevertAllSwitchesEveryAppOffOnQuit() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidActivate(pid: 11)
        s.ea.applicationDidDeactivate(pid: 11)             // 11 is waiting out its grace period
        s.ea.revertAll()
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 11))
        XCTAssertEqual(s.enhancedWrites.filter { !$0.on }.map { $0.pid }.sorted(), [10, 11])
        s.fireLastTimer()                                  // the pending timer finds nothing left to do
        XCTAssertEqual(s.offWrites, 2)
    }

    // A failed or timed-out write is not a verdict (review point 6)

    func testAPassingFailureIsRetriedOnTheNextActivationNotRecordedAsPermanent() {
        let s = FallbackStub()
        var failures = 1
        s.enhanced = { _, _ in
            if failures > 0 { failures -= 1; return .apiDisabled }
            return .success
        }
        XCTAssertEqual(s.ea.apply(pid: 10), .unsupported, "the first write failed for a passing reason")
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))

        XCTAssertTrue(s.ea.applicationDidActivate(pid: 10))
        XCTAssertEqual(s.ea.support(pid: 10), .enhancedFallback)
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10))
    }

    func testAFailingHostIsAskedAtMostThreeTimesPerActivationThenAgainAfterItLeaves() {
        let s = FallbackStub()
        s.enhanced = { _, _ in .apiDisabled }
        s.ea.applicationDidActivate(pid: 10)               // first contact: write 1
        s.ea.applicationDidActivate(pid: 10)               // write 2
        s.ea.applicationDidActivate(pid: 10)               // write 3
        XCTAssertFalse(s.ea.applicationDidActivate(pid: 10), "enough: a busy host is left alone")
        XCTAssertEqual(s.onWrites, ElectronAccessibility.maxEnhancedFailures)

        s.ea.applicationDidDeactivate(pid: 10)             // leaves and returns: a fresh budget
        XCTAssertTrue(s.ea.applicationDidActivate(pid: 10))
        XCTAssertEqual(s.onWrites, ElectronAccessibility.maxEnhancedFailures + 1)
    }

    func testATimedOutWriteIsStillSwitchedOffLaterAndRetriedUntilConfirmed() {
        let s = FallbackStub()
        var reply: AXError = .cannotComplete
        s.enhanced = { _, on in on ? reply : .success }
        s.ea.applicationDidActivate(pid: 10)
        XCTAssertTrue(s.ea.isEnhancedActive(pid: 10), "it may have been applied, so we owe it a `false`")
        XCTAssertEqual(s.ea.support(pid: 10), .unsupported, "but nothing is known to work yet")

        reply = .success
        XCTAssertTrue(s.ea.applicationDidActivate(pid: 10), "tried again, and this one is confirmed")
        XCTAssertEqual(s.ea.support(pid: 10), .enhancedFallback)

        s.ea.applicationDidDeactivate(pid: 10)
        s.fireLastTimer()
        XCTAssertEqual(s.offWrites, 1)
    }

    func testAnUnconfirmedTimedOutWriteIsStillRevertedOnQuit() {
        let s = FallbackStub()
        s.enhanced = { _, on in on ? .cannotComplete : .success }
        s.ea.applicationDidActivate(pid: 10)
        s.ea.revertAll()
        XCTAssertEqual(s.enhancedWrites.last?.on, false)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
    }

    // A quit app is forgotten, pids are reused

    func testAProcessThatReusesAPidDoesNotInheritTheOldVerdictOrFlag() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        XCTAssertEqual(s.ea.support(pid: 10), .enhancedFallback)

        s.ea.applicationDidTerminate(pid: 10)
        XCTAssertEqual(s.ea.support(pid: 10), .unknown)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.offWrites, 0, "the process is gone: nothing to switch off")

        s.chromium = { _ in false }                        // pid 10 is now a native app
        s.ea.applicationDidActivate(pid: 10)
        XCTAssertEqual(s.ea.support(pid: 10), .unsupported)
        XCTAssertFalse(s.ea.isEnhancedActive(pid: 10))
        XCTAssertEqual(s.manualWrites, [10, 10], "a new process gets its own first attempt")
        XCTAssertEqual(s.chromiumAsks, [10, 10], "and its own bundle check")
    }

    func testAPendingSwitchOffForAQuitAppDoesNothing() {
        let s = FallbackStub()
        s.ea.applicationDidActivate(pid: 10)
        s.ea.applicationDidDeactivate(pid: 10)
        s.ea.applicationDidTerminate(pid: 10)
        s.fireLastTimer()
        XCTAssertEqual(s.offWrites, 0)
    }
}
