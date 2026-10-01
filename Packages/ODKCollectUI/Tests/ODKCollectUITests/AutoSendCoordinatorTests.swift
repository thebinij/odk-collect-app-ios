import Combine
import OpenRosaKit
import ProjectSettingsKit
import UIKit
import XCTest
@testable import ODKCollectUI

/// Lets tests flip connectivity on command — and, crucially, distinguish a real
/// transition (which publishes) from "already in this state, no transition event
/// observed" (which doesn't). The latter is what a foreground notification covers
/// in production when the connection never actually changed.
private final class FakeConnectivity: ConnectivityMonitoring {
    private let subject = PassthroughSubject<Void, Never>()

    private(set) var isOnline: Bool
    private(set) var isOnWiFi: Bool
    private(set) var isOnCellular: Bool
    var connectivityChanges: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    init(isOnline: Bool, isOnWiFi: Bool = false, isOnCellular: Bool = false) {
        self.isOnline = isOnline
        self.isOnWiFi = isOnWiFi
        self.isOnCellular = isOnCellular
    }

    /// Simulates a real connectivity change: updates state *and* publishes it.
    func setState(isOnline: Bool, isOnWiFi: Bool = false, isOnCellular: Bool = false) {
        self.isOnline = isOnline
        self.isOnWiFi = isOnWiFi
        self.isOnCellular = isOnCellular
        subject.send(())
    }

    /// Simulates "already in this state, no transition event": updates state
    /// without publishing, so the only thing that can trigger a sweep is some
    /// *other* event (e.g. a foreground notification).
    func setStateQuietly(isOnline: Bool, isOnWiFi: Bool = false, isOnCellular: Bool = false) {
        self.isOnline = isOnline
        self.isOnWiFi = isOnWiFi
        self.isOnCellular = isOnCellular
    }
}

/// Thread-safe recorder for what the injected send routine did. The coordinator's
/// `Send` closure is non-isolated, so it runs off the main actor — the lock keeps
/// these reads/writes (and the "max in flight" tracking) deterministic.
private final class SendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    var sentIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    func recordStart(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.append(id)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func recordEnd() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
    }
}

private enum TestError: Error {
    case sendFailed
}

/// Yields a few times so any `@MainActor` tasks the coordinator spawned *synchronously*
/// (e.g. the `$autoSend`/`$submissions` initial emissions on `start()`) get a chance to
/// run to completion before the test flips the next trigger. Without this, those
/// start-time sweeps could race ahead and observe a connectivity/mode change meant for
/// later.
@MainActor
private func settleMainActor() async {
    for _ in 0..<5 { await Task.yield() }
}

@MainActor
final class AutoSendCoordinatorTests: XCTestCase {
    private struct Harness {
        let store: SubmissionStore
        let settings: FormSubmissionSettingsStore
        let connectivity: FakeConnectivity
        let project: Project
    }

    private var tempDirectory: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaultsSuite = "AutoSendCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeHarness(
        isOnline: Bool,
        isOnWiFi: Bool,
        isOnCellular: Bool,
        autoSend: AutoSendMode
    ) -> Harness {
        let settings = FormSubmissionSettingsStore(defaults: defaults)
        settings.autoSend = autoSend
        return Harness(
            store: SubmissionStore(directory: tempDirectory),
            settings: settings,
            connectivity: FakeConnectivity(isOnline: isOnline, isOnWiFi: isOnWiFi, isOnCellular: isOnCellular),
            project: Project(serverURL: URL(string: "https://example.com")!, username: "user")
        )
    }

    /// The production `send` marks the submission `.sent` on success; tests mirror that
    /// side effect (rather than just recording), because the coordinator's sweeps are
    /// triggered by `readyToSendSubmissions` — if an injected success didn't mark sent,
    /// a second queued sweep would re-send the same entry and double-count it.
    private func makeSuccessfulSend(
        recorder: SendRecorder,
        store: SubmissionStore,
        completion: XCTestExpectation,
        delayNanoseconds: UInt64 = 0
    ) -> AutoSendCoordinator.Send {
        { submission, _, _ in
            recorder.recordStart(submission.id)
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            store.markSent(submission.id)
            recorder.recordEnd()
            completion.fulfill()
        }
    }

    private func makeCoordinator(
        harness: Harness,
        project: Project?,
        send: @escaping AutoSendCoordinator.Send
    ) -> AutoSendCoordinator {
        AutoSendCoordinator(
            settings: harness.settings,
            connectivity: harness.connectivity,
            submissionStore: harness.store,
            projectProvider: { project },
            passwordProvider: { "password" },
            send: send
        )
    }

    // MARK: - Off

    /// Auto Send Off is the default and must have *zero* behavior change from the
    /// pre-feature world: no connectivity change, foreground return, or newly-saved
    /// submission ever sends on its own.
    func testOffNeverSendsAutomatically() throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: false, autoSend: .off)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: { submission, _, _ in
                recorder.recordStart(submission.id)
                recorder.recordEnd()
            }
        )

        coordinator.start()

        // Every auto-send trigger, in sequence — none may do anything when Off.
        harness.connectivity.setState(isOnline: false)
        harness.connectivity.setState(isOnline: true, isOnWiFi: true)
        harness.connectivity.setState(isOnline: true, isOnCellular: true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        XCTAssertTrue(recorder.sentIDs.isEmpty)
    }

    // MARK: - Auto Send triggers (any connection)

    func testWifiOrCellularSendsOnOfflineToOnlineTransition() async throws {
        let harness = makeHarness(isOnline: false, isOnWiFi: false, isOnCellular: false, autoSend: .wifiOrCellular)
        let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let sent = expectation(description: "sent")
        sent.expectedFulfillmentCount = 1
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent)
        )

        coordinator.start()
        await settleMainActor()          // start-time sweeps run while offline → no-op
        harness.connectivity.setState(isOnline: true, isOnWiFi: true)   // offline→online → the sweep

        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(recorder.sentIDs, [submission.id])
        XCTAssertTrue(harness.store.readyToSendSubmissions.isEmpty)
    }

    func testWifiOrCellularSendsOnForegroundWhileOnline() async throws {
        let harness = makeHarness(isOnline: false, isOnWiFi: false, isOnCellular: false, autoSend: .wifiOrCellular)
        let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let sent = expectation(description: "sent")
        sent.expectedFulfillmentCount = 1
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent)
        )

        coordinator.start()
        await settleMainActor()                 // offline → no-op
        harness.connectivity.setStateQuietly(isOnline: true, isOnWiFi: true)   // already online, no transition event
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(recorder.sentIDs, [submission.id])
        XCTAssertTrue(harness.store.readyToSendSubmissions.isEmpty)
    }

    func testWifiOrCellularSendsWhenNewSubmissionSavedWhileOnline() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: false, autoSend: .wifiOrCellular)

        let recorder = SendRecorder()
        let sent = expectation(description: "sent")
        sent.expectedFulfillmentCount = 1
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent)
        )

        coordinator.start()
        await settleMainActor()   // online but nothing waiting → no-op

        let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(recorder.sentIDs, [submission.id])
        XCTAssertTrue(harness.store.readyToSendSubmissions.isEmpty)
    }

    /// Switching Auto Send on is itself a trigger (§5), so existing Ready to Send
    /// items are picked up on the next sweep without waiting for connectivity to flap.
    func testSwitchingToWifiOrCellularWhileOnlineTriggersASweep() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: false, autoSend: .off)
        let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let sent = expectation(description: "sent")
        sent.expectedFulfillmentCount = 1
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent)
        )

        coordinator.start()
        await settleMainActor()          // off → no-op
        harness.settings.autoSend = .wifiOrCellular   // toggle on → trigger

        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(recorder.sentIDs, [submission.id])
    }

    // MARK: - Failure & concurrency

    /// A failed automatic attempt must leave the submission `.readyToSend` (not stuck
    /// in a bad state) and must not retry in a tight loop — exactly one attempt per
    /// trigger.
    func testFailedAutoSendLeavesSubmissionReadyToSendAndDoesNotRetry() async throws {
        let harness = makeHarness(isOnline: false, isOnWiFi: false, isOnCellular: false, autoSend: .wifiOrCellular)
        let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let attempted = expectation(description: "attempted")
        attempted.expectedFulfillmentCount = 1
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: { submission, _, _ in
                recorder.recordStart(submission.id)
                recorder.recordEnd()
                attempted.fulfill()
                throw TestError.sendFailed
            }
        )

        coordinator.start()
        await settleMainActor()          // offline → no-op
        harness.connectivity.setState(isOnline: true, isOnWiFi: true)   // the single trigger

        await fulfillment(of: [attempted], timeout: 2)
        XCTAssertEqual(recorder.sentIDs, [submission.id], "exactly one attempt — no tight loop")
        XCTAssertEqual(harness.store.readyToSendSubmissions.map(\.id), [submission.id], "still waiting to send")
    }

    /// Flapping connectivity (or any burst of triggers) must never start overlapping
    /// sweeps, and must not double-send anything: sends run one at a time, in order.
    func testConcurrentTriggersDoNotCauseOverlappingSweeps() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: false, autoSend: .wifiOrCellular)
        let a = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)
        let b = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)
        let c = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let sent = expectation(description: "sent")
        sent.expectedFulfillmentCount = 3
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent, delayNanoseconds: 30_000_000)
        )

        coordinator.start()
        // Burst of extra triggers right on top of the start-time sweeps.
        harness.connectivity.setState(isOnline: false)
        harness.connectivity.setState(isOnline: true, isOnWiFi: true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await fulfillment(of: [sent], timeout: 5)

        XCTAssertEqual(recorder.maxInFlight, 1, "sends must be sequential, never overlapping")
        XCTAssertEqual(Set(recorder.sentIDs), Set([a.id, b.id, c.id]), "every submission sent")
        XCTAssertEqual(recorder.sentIDs.count, 3, "each submission sent exactly once")
        XCTAssertTrue(harness.store.readyToSendSubmissions.isEmpty)
    }

    // MARK: - Edge cases

    /// No project configured ⇒ nothing to authenticate with ⇒ automatic send has
    /// nothing to do, regardless of connectivity.
    func testNoProjectConfiguredDoesNothing() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: false, autoSend: .wifiOrCellular)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let coordinator = makeCoordinator(
            harness: harness,
            project: nil,
            send: { submission, _, _ in
                recorder.recordStart(submission.id)
                recorder.recordEnd()
            }
        )

        coordinator.start()
        await settleMainActor()

        harness.connectivity.setState(isOnline: false)
        harness.connectivity.setState(isOnline: true, isOnWiFi: true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settleMainActor()

        XCTAssertTrue(recorder.sentIDs.isEmpty)
    }

    /// Switching Auto Send off must stop future automatic sweeps (in-flight sends are
    /// allowed to finish, but nothing new is queued).
    func testSwitchingToOffPreventsAutomaticSends() async throws {
        let harness = makeHarness(isOnline: false, isOnWiFi: false, isOnCellular: false, autoSend: .wifiOrCellular)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let coordinator = makeCoordinator(
            harness: harness,
            project: harness.project,
            send: { submission, _, _ in
                recorder.recordStart(submission.id)
                recorder.recordEnd()
            }
        )

        coordinator.start()
        await settleMainActor()          // offline → no-op

        harness.settings.autoSend = .off  // toggle off
        harness.connectivity.setState(isOnline: true, isOnWiFi: true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settleMainActor()

        XCTAssertTrue(recorder.sentIDs.isEmpty)
    }

    // MARK: - Auto Send mode matching ("send when")

    func testWifiOnlyDoesNotSendOverCellular() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: false, isOnCellular: true, autoSend: .wifiOnly)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let coordinator = makeCoordinator(harness: harness, project: harness.project, send: { s, _, _ in
            recorder.recordStart(s.id); recorder.recordEnd()
        })

        coordinator.start()
        await settleMainActor()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settleMainActor()

        XCTAssertTrue(recorder.sentIDs.isEmpty)
    }

    func testWifiOnlySendsWhenWifiBecomesAvailable() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: false, isOnCellular: true, autoSend: .wifiOnly)
        let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let sent = expectation(description: "sent")
        let coordinator = makeCoordinator(
            harness: harness, project: harness.project,
            send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent)
        )

        coordinator.start()
        await settleMainActor()
        harness.connectivity.setState(isOnline: true, isOnWiFi: true, isOnCellular: false)

        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(recorder.sentIDs, [submission.id])
    }

    func testCellularOnlyDoesNotSendWhileWifiIsAlsoActive() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: true, autoSend: .cellularOnly)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let coordinator = makeCoordinator(harness: harness, project: harness.project, send: { s, _, _ in
            recorder.recordStart(s.id); recorder.recordEnd()
        })

        coordinator.start()
        await settleMainActor()

        XCTAssertTrue(recorder.sentIDs.isEmpty)
    }

    func testCellularOnlySendsOverCellularAlone() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: false, isOnCellular: true, autoSend: .cellularOnly)
        let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let sent = expectation(description: "sent")
        let coordinator = makeCoordinator(
            harness: harness, project: harness.project,
            send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent)
        )

        coordinator.start()
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(recorder.sentIDs, [submission.id])
    }

    func testWifiOrCellularSendsOverEitherAlone() async throws {
        // Two harnesses covering both single-transport cases; wifiOrCellular
        // ignores the distinction entirely.
        for (isOnWiFi, isOnCellular) in [(true, false), (false, true)] {
            let harness = makeHarness(isOnline: true, isOnWiFi: isOnWiFi, isOnCellular: isOnCellular, autoSend: .wifiOrCellular)
            let submission = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

            let recorder = SendRecorder()
            let sent = expectation(description: "sent")
            let coordinator = makeCoordinator(
                harness: harness, project: harness.project,
                send: makeSuccessfulSend(recorder: recorder, store: harness.store, completion: sent)
            )

            coordinator.start()
            await fulfillment(of: [sent], timeout: 2)
            XCTAssertEqual(recorder.sentIDs, [submission.id])
        }
    }

    /// The core requirement carried over unchanged from the original plan: Off
    /// must never submit anything on its own, regardless of connection type.
    func testOffNeverSendsRegardlessOfConnectionType() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: true, autoSend: .off)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let coordinator = makeCoordinator(harness: harness, project: harness.project, send: { s, _, _ in
            recorder.recordStart(s.id); recorder.recordEnd()
        })

        coordinator.start()
        harness.connectivity.setState(isOnline: false)
        harness.connectivity.setState(isOnline: true, isOnWiFi: true)
        harness.connectivity.setState(isOnline: true, isOnCellular: true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settleMainActor()

        XCTAssertTrue(recorder.sentIDs.isEmpty)
        XCTAssertEqual(harness.store.readyToSendSubmissions.count, 1, "stays in Ready to Send")
    }

    /// A mid-sweep transition off the eligible connection (e.g. Wi-Fi drops while
    /// "Wi-Fi only" is selected and a second submission is still queued) must stop
    /// further sends without erroring the in-flight one.
    func testWifiOnlyStopsSweepIfWifiDropsMidSweep() async throws {
        let harness = makeHarness(isOnline: true, isOnWiFi: true, isOnCellular: false, autoSend: .wifiOnly)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)
        _ = try harness.store.save(xml: "<d/>", xformXML: "<h/>", formID: "f", formName: "F", status: .readyToSend)

        let recorder = SendRecorder()
        let firstSent = expectation(description: "first sent")
        let coordinator = makeCoordinator(
            harness: harness, project: harness.project,
            send: { submission, _, _ in
                recorder.recordStart(submission.id)
                harness.connectivity.setStateQuietly(isOnline: true, isOnCellular: true) // Wi-Fi drops mid-send
                harness.store.markSent(submission.id)
                recorder.recordEnd()
                firstSent.fulfill()
            }
        )

        coordinator.start()
        await fulfillment(of: [firstSent], timeout: 2)
        await settleMainActor()

        XCTAssertEqual(recorder.sentIDs.count, 1, "only the in-flight submission is sent — Wi-Fi dropped before the rest")
        XCTAssertEqual(harness.store.readyToSendSubmissions.count, 1, "the second submission stays in Ready to Send")
    }
}
