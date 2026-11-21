import Foundation
import Testing
@testable import SplatVision

/// Plays the system (open/dismiss) and the renderer (events) around an ImmersiveController.
@MainActor
private final class FakeSpace {
    let controller = ImmersiveController()
    var opened: [SplatSource] = []
    /// How long a "load" takes after opening.
    var loadTime: Duration = .milliseconds(100)
    /// If false, the renderer never confirms `.closed` (stuck shutdown).
    var confirmsClose = true

    init() {
        controller.closeTimeout = .milliseconds(500)
        controller.loadSettleTimeout = .seconds(2)
        controller.configure(open: { [unowned self] request in
            self.opened.append(request.source)
            let controller = self.controller
            let loadTime = self.loadTime
            Task { @MainActor in
                controller.handle(.loading, requestID: request.id)
                try? await Task.sleep(for: loadTime)
                controller.handle(.loaded(LoadReport(splatCount: 1)), requestID: request.id)
            }
            return .opened
        }, dismiss: { [unowned self] in
            guard self.confirmsClose, let id = self.controller.currentRequest?.id else { return }
            let controller = self.controller
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                controller.handle(.closed, requestID: id)
            }
        })
    }

    func waitIdle(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while controller.isTransitioning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
struct ImmersiveControllerTests {
    private let a = SplatSource.localFile(URL(fileURLWithPath: "/tmp/a.ply"))
    private let b = SplatSource.localFile(URL(fileURLWithPath: "/tmp/b.ply"))
    private let c = SplatSource.localFile(URL(fileURLWithPath: "/tmp/c.ply"))

    @Test func rapidRequestsCollapseIntoTheLatest() async {
        let space = FakeSpace()
        space.loadTime = .milliseconds(300)
        space.controller.show(a)
        try? await Task.sleep(for: .milliseconds(50))  // A is opening/loading
        space.controller.show(b)
        space.controller.show(c)
        await space.waitIdle()
        #expect(space.opened == [a, c])  // B was superseded before it ever opened
        #expect(space.controller.displayedSource == c)
    }

    @Test func closeRequestedDuringASwitchWins() async {
        let space = FakeSpace()
        space.controller.show(a)
        await space.waitIdle()
        space.controller.show(b)
        try? await Task.sleep(for: .milliseconds(5))  // switching A → B, closing A
        space.controller.close()
        await space.waitIdle()
        #expect(space.opened == [a])  // B never opened
        #expect(space.controller.state == .closed)
    }

    @Test func switchTargetStaysProtectedWhileTheOldSpaceCloses() async {
        let space = FakeSpace()
        space.controller.show(a)
        await space.waitIdle()
        space.controller.show(b)
        try? await Task.sleep(for: .milliseconds(10))  // pending consumed, A still closing
        #expect(space.controller.protectedFiles.contains(URL(fileURLWithPath: "/tmp/b.ply").standardizedFileURL))
        await space.waitIdle()
    }

    @Test func stuckShutdownAbortsInsteadOfOpeningTheNext() async {
        let space = FakeSpace()
        space.controller.show(a)
        await space.waitIdle()
        space.confirmsClose = false
        space.controller.show(b)
        await space.waitIdle()
        #expect(space.opened == [a])
        #expect(space.controller.lastOpenError != nil)
    }

    @Test func maintenanceRunsOnlyAfterACleanClose() async {
        let space = FakeSpace()
        space.controller.show(a)
        await space.waitIdle()
        var ran = false
        let result = await space.controller.closeForMaintenance { ran = true }
        #expect(ran)
        #expect((try? result.get()) != nil)
        #expect(space.controller.state == .closed)
    }

    @Test func maintenanceBlocksNewShowsAndFailsIfTheSpaceWillNotClose() async {
        let space = FakeSpace()
        space.controller.show(a)
        await space.waitIdle()
        space.confirmsClose = false
        var ran = false
        async let result = space.controller.closeForMaintenance { ran = true }
        try? await Task.sleep(for: .milliseconds(10))
        space.controller.show(b)  // ignored while locked
        let outcome = await result
        #expect(!ran)
        #expect((try? outcome.get()) == nil)
        #expect(space.opened == [a])
    }

    @Test(arguments: [true, false])
    func firstSortIsKeptWhicheverEventArrivesFirst(sortFirst: Bool) async throws {
        let controller = ImmersiveController()
        controller.configure(open: { _ in .opened }, dismiss: {})
        controller.show(a)
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.isTransitioning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(controller.currentRequest?.id)
        if sortFirst {
            controller.handle(.firstSortCompleted(seconds: 0.7), requestID: id)
            controller.handle(.loaded(LoadReport(splatCount: 10)), requestID: id)
        } else {
            controller.handle(.loaded(LoadReport(splatCount: 10)), requestID: id)
            controller.handle(.firstSortCompleted(seconds: 0.7), requestID: id)
        }
        guard case let .loaded(report) = controller.loadState else {
            Issue.record("expected loaded, got \(controller.loadState)")
            return
        }
        #expect(report.firstSortSeconds == 0.7)
    }
}
