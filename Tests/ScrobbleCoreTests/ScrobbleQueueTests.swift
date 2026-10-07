import SwiftData
import XCTest
@testable import ScrobbleCore

@MainActor
final class ScrobbleQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let lbOK = StubTransport.Response.json(#"{"status":"ok"}"#)

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: ScrobbleRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        defaults = UserDefaults(suiteName: "ScrobbleQueueTests-\(UUID())")
    }

    private func lastfmAccepted(_ count: Int, ignoredCodes: [Int]? = nil) -> StubTransport.Response {
        let codes = ignoredCodes ?? Array(repeating: 0, count: count)
        let items = codes.map { ##"{"ignoredMessage":{"code":"\##($0)","#text":""}}"## }.joined(separator: ",")
        let ignored = codes.filter { $0 != 0 }.count
        return .json(##"{"scrobbles":{"@attr":{"accepted":\##(count - ignored),"ignored":\##(ignored)},"scrobble":[\##(items)]}}"##)
    }

    private func queue(
        lastfm: StubTransport, listenbrainz: StubTransport,
        sessionKey: String? = "SK", token: String? = "TOKEN"
    ) -> ScrobbleQueue {
        ScrobbleQueue(
            context: container.mainContext,
            lastfm: LastFMClient(apiKey: "key", sharedSecret: "secret", transport: lastfm),
            listenbrainz: ListenBrainzClient(transport: listenbrainz),
            resolver: nil,
            credentials: { Credentials(lastfmSessionKey: sessionKey, listenbrainzToken: token) },
            defaults: defaults
        )
    }

    private func enqueue(_ queue: ScrobbleQueue, _ tracks: [String]) async throws -> [ScrobbleRecord] {
        var records: [ScrobbleRecord] = []
        for (index, track) in tracks.enumerated() {
            let scrobble = Scrobble(artist: "Artist", track: track, durationSec: 200,
                                    listenedAt: now - Double((tracks.count - index) * 300))
            records.append(try await queue.enqueue(scrobble, source: .mac, now: now))
        }
        return records
    }

    func testFlushSendsToBothServicesAndMarksBothFlags() async throws {
        let lastfm = StubTransport(lastfmAccepted(2))
        let lb = StubTransport(lbOK)
        let queue = queue(lastfm: lastfm, listenbrainz: lb)
        let records = try await enqueue(queue, ["One", "Two"])

        let report = await queue.flush(now: now)

        XCTAssertEqual(report.lastfmSent, 2)
        XCTAssertEqual(report.listenbrainzSent, 2)
        XCTAssertTrue(records.allSatisfy { $0.lastfmSent && $0.listenbrainzSent })
        XCTAssertEqual(lastfm.requests.first?.formParameters["track[1]"], "Two")
        XCTAssertEqual(lb.requests.first?.jsonBody?["listen_type"] as? String, "import", "several listens go as import")
        XCTAssertEqual(queue.pendingCount(), 0)
    }

    func testSingleListenGoesToListenBrainzAsSingle() async throws {
        let lb = StubTransport(lbOK)
        let queue = queue(lastfm: StubTransport(lastfmAccepted(1)), listenbrainz: lb)
        _ = try await enqueue(queue, ["One"])
        _ = await queue.flush(now: now)
        XCTAssertEqual(lb.requests.first?.jsonBody?["listen_type"] as? String, "single")
    }

    func testPartialSuccessOnlyRetriesTheFailedService() async throws {
        let lastfm = StubTransport(lastfmAccepted(1))
        let lb = StubTransport(.json(#"{"code":503}"#, status: 503), lbOK)
        let queue = queue(lastfm: lastfm, listenbrainz: lb)
        let record = try await enqueue(queue, ["One"])[0]

        _ = await queue.flush(now: now)
        XCTAssertTrue(record.lastfmSent)
        XCTAssertFalse(record.listenbrainzSent)
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.nextAttemptAt, now + 30)

        _ = await queue.flush(now: now + 10)
        XCTAssertEqual(lb.requests.count, 1, "not due yet")

        _ = await queue.flush(now: now + 30)
        XCTAssertTrue(record.listenbrainzSent)
        XCTAssertEqual(lastfm.requests.count, 1, "Last.fm isn't resent")
    }

    func testListenBrainzRetryAfterLengthensTheWait() async throws {
        let lb = StubTransport(.json(#"{"code":429}"#, status: 429, headers: ["Retry-After": "600"]))
        let queue = queue(lastfm: StubTransport(lastfmAccepted(1)), listenbrainz: lb)
        let record = try await enqueue(queue, ["One"])[0]
        _ = await queue.flush(now: now)
        XCTAssertEqual(record.nextAttemptAt, now + 600)
    }

    func testIgnoredByLastFMCountsAsSentExceptDailyLimit() async throws {
        let lastfm = StubTransport(lastfmAccepted(2, ignoredCodes: [3, 5]))
        let queue = queue(lastfm: lastfm, listenbrainz: StubTransport(lbOK))
        let records = try await enqueue(queue, ["TooOld", "DailyLimit"])
        _ = await queue.flush(now: now)
        XCTAssertTrue(records[0].lastfmSent, "code 3 (timestamp too old) won't change on retry")
        XCTAssertFalse(records[1].lastfmSent, "code 5 (daily limit) is retried later")
        XCTAssertEqual(records[1].attempts, 1)
    }

    func testMissingCredentialsLeaveRecordsPendingWithoutCountingAttempts() async throws {
        let lastfm = StubTransport()
        let lb = StubTransport(lbOK)
        let queue = queue(lastfm: lastfm, listenbrainz: lb, sessionKey: nil)
        let record = try await enqueue(queue, ["One"])[0]
        _ = await queue.flush(now: now)
        XCTAssertTrue(lastfm.requests.isEmpty)
        XCTAssertFalse(record.lastfmSent)
        XCTAssertTrue(record.listenbrainzSent)
        XCTAssertEqual(record.attempts, 0)
        XCTAssertEqual(queue.status.lastfm, .notConnected)
    }

    func testInvalidSessionAsksForLoginWithoutCountingAttempts() async throws {
        let lastfm = StubTransport(.json(#"{"error":9,"message":"Invalid session key"}"#, status: 403))
        let queue = queue(lastfm: lastfm, listenbrainz: StubTransport(lbOK))
        let record = try await enqueue(queue, ["One"])[0]
        _ = await queue.flush(now: now)
        XCTAssertEqual(queue.status.lastfm, .needsLogin)
        XCTAssertEqual(record.attempts, 0)
    }

    // Edge case: a banned client (error 26) stops Last.fm scrobbling and says so.
    func testSuspendedAPIKeyDisablesLastFMUntilCleared() async throws {
        let lastfm = StubTransport(.json(#"{"error":26,"message":"Suspended API key"}"#, status: 403))
        let queue = queue(lastfm: lastfm, listenbrainz: StubTransport(lbOK, lbOK))
        _ = try await enqueue(queue, ["One"])
        _ = await queue.flush(now: now)
        XCTAssertEqual(queue.status.lastfm, .suspended)

        _ = try await enqueue(queue, ["Two"])
        _ = await queue.flush(now: now + 3600)
        XCTAssertEqual(lastfm.requests.count, 1, "no more Last.fm calls while suspended")

        let reopened = self.queue(lastfm: StubTransport(), listenbrainz: StubTransport())
        XCTAssertEqual(reopened.status.lastfm, .suspended, "persists across launches")
        reopened.clearLastFMSuspension()
        XCTAssertEqual(reopened.status.lastfm, .unknown)
    }

    func testTenFailuresMarkPermanentlyFailed() async throws {
        let failures = (0..<10).map { _ in StubTransport.Response(status: 500, body: Data()) }
        let lastfm = StubTransport(failures[0], failures[1], failures[2], failures[3], failures[4],
                                   failures[5], failures[6], failures[7], failures[8], failures[9])
        let queue = queue(lastfm: lastfm, listenbrainz: StubTransport(lbOK), token: nil)
        let record = try await enqueue(queue, ["One"])[0]
        var clock = now
        for _ in 0..<10 {
            _ = await queue.flush(now: clock)
            clock = (record.nextAttemptAt ?? clock) + 1
        }
        XCTAssertTrue(record.permanentlyFailed)
        XCTAssertEqual(queue.failedCount(), 1)
    }

    func testEnqueueDeduplicates() async throws {
        let queue = queue(lastfm: StubTransport(), listenbrainz: StubTransport())
        let play = Scrobble(artist: "A", track: "B", listenedAt: now)
        _ = try await queue.enqueue(play, source: .foreground, now: now)
        _ = try await queue.enqueue(play, source: .poll, now: now)
        XCTAssertEqual(queue.pendingCount(), 1)
    }

    func testRetryNowClearsFailureState() async throws {
        let queue = queue(lastfm: StubTransport(), listenbrainz: StubTransport())
        let record = try await enqueue(queue, ["One"])[0]
        record.attempts = 10
        record.permanentlyFailed = true
        record.nextAttemptAt = now + 999
        queue.retryNow(record)
        XCTAssertEqual(record.attempts, 0)
        XCTAssertFalse(record.permanentlyFailed)
        XCTAssertNil(record.nextAttemptAt)
    }
}

final class AuthTests: XCTestCase {
    func testLastFMAuthURLAndCallbackToken() throws {
        XCTAssertEqual(
            LastFMAuth.authorizationURL(apiKey: "KEY").absoluteString,
            "https://www.last.fm/api/auth/?api_key=KEY&cb=scrobblekit://lastfm-callback"
        )
        XCTAssertEqual(LastFMAuth.token(from: URL(string: "scrobblekit://lastfm-callback?token=abc123")!), "abc123")
        XCTAssertNil(LastFMAuth.token(from: URL(string: "scrobblekit://other?token=abc123")!))
        XCTAssertNil(LastFMAuth.token(from: URL(string: "scrobblekit://lastfm-callback")!))
    }

    func testLastFMLoginStoresSessionInKeychain() async throws {
        let keychain = InMemoryKeychain()
        let store = KeychainStore(backend: keychain)
        let transport = StubTransport(.json(#"{"session":{"name":"feruz","key":"SK1","subscriber":0}}"#))
        let auth = LastFMAuth(client: LastFMClient(apiKey: "k", sharedSecret: "s", transport: transport), keychain: store)

        let session = try await auth.completeLogin(token: "tok")
        XCTAssertEqual(session.username, "feruz")
        XCTAssertEqual(auth.sessionKey, "SK1")
        XCTAssertEqual(auth.username, "feruz")

        auth.logOut()
        XCTAssertNil(auth.sessionKey)
        XCTAssertNil(auth.username)
    }

    func testListenBrainzConnectValidatesBeforeStoring() async throws {
        let store = KeychainStore(backend: InMemoryKeychain())
        let invalid = ListenBrainzAuth(
            client: ListenBrainzClient(transport: StubTransport(.json(#"{"code":200,"valid":false}"#))), keychain: store
        )
        do {
            _ = try await invalid.connect(token: "bad")
            XCTFail("expected invalidToken")
        } catch {
            XCTAssertEqual(error as? ListenBrainzError, .invalidToken)
        }
        XCTAssertNil(invalid.token)

        let valid = ListenBrainzAuth(
            client: ListenBrainzClient(transport: StubTransport(.json(#"{"code":200,"valid":true,"user_name":"urazaliev"}"#))),
            keychain: store
        )
        let user = try await valid.connect(token: "  good-token \n")
        XCTAssertEqual(user, "urazaliev")
        XCTAssertEqual(valid.token, "good-token", "whitespace from pasting is trimmed")
        XCTAssertEqual(valid.username, "urazaliev")
    }

    func testListenBrainzListensDecode() async throws {
        let transport = StubTransport(.json("""
        {"payload":{"count":1,"user_id":"urazaliev","listens":[
          {"listened_at":1700000000,"track_metadata":{"artist_name":"Radiohead","track_name":"Reckoner","release_name":"In Rainbows"}}]}}
        """))
        let listens = try await ListenBrainzClient(transport: transport)
            .listens(user: "urazaliev", since: Date(timeIntervalSince1970: 1_699_990_000))
        XCTAssertEqual(listens, [Scrobble(artist: "Radiohead", track: "Reckoner", album: "In Rainbows",
                                          listenedAt: Date(timeIntervalSince1970: 1_700_000_000))])
        XCTAssertEqual(
            transport.requests.first?.url?.absoluteString,
            "https://api.listenbrainz.org/1/user/urazaliev/listens?min_ts=1699990000&count=100"
        )
    }
}
