import XCTest
@testable import OpenRosaKit

private struct StubError: Error {}

final class OfflineFallbackTests: XCTestCase {
    func testReturnsThePrimaryValueMarkedLiveWhenItSucceeds() async throws {
        let result = try await OfflineFallback.resolve(
            primary: { "fresh" },
            cached: { "stale" }
        )
        XCTAssertEqual(result.value, "fresh")
        XCTAssertEqual(result.source, .live)
    }

    func testFallsBackToTheCachedValueMarkedCachedWhenThePrimaryThrows() async throws {
        let result = try await OfflineFallback.resolve(
            primary: { throw StubError() },
            cached: { "stale" }
        )
        XCTAssertEqual(result.value, "stale")
        XCTAssertEqual(result.source, .cached)
    }

    /// The whole point: don't silently swallow a real failure just because there's
    /// nothing to fall back to — the caller still needs to know it failed.
    func testRethrowsThePrimarysErrorWhenThereIsNothingCached() async {
        do {
            _ = try await OfflineFallback.resolve(
                primary: { () throws -> String in throw StubError() },
                cached: { nil }
            )
            XCTFail("expected the primary's error to propagate")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("expected a StubError, got \(error)")
        }
    }

    func testDoesNotConsultTheCacheAtAllWhenThePrimarySucceeds() async throws {
        var cacheWasConsulted = false
        _ = try await OfflineFallback.resolve(
            primary: { "fresh" },
            cached: {
                cacheWasConsulted = true
                return "stale"
            }
        )
        XCTAssertFalse(cacheWasConsulted, "a successful live fetch should never even look at the cache")
    }
}
