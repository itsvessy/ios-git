import Core
import XCTest

final class SSHRemoteURLTests: XCTestCase {
    func testParsesSCPStyleURL() throws {
        let remote = try SSHRemoteURL(parse: "git@github.com:owner/repo.git")
        XCTAssertEqual(remote.user, "git")
        XCTAssertEqual(remote.host, "github.com")
        XCTAssertEqual(remote.port, 22)
        XCTAssertEqual(remote.path, "owner/repo.git")
    }

    func testParsesSSHURLWithPort() throws {
        let remote = try SSHRemoteURL(parse: "ssh://git@example.com:2222/org/repo.git")
        XCTAssertEqual(remote.user, "git")
        XCTAssertEqual(remote.host, "example.com")
        XCTAssertEqual(remote.port, 2222)
        XCTAssertEqual(remote.path, "org/repo.git")
    }

    func testRejectsNonSSHScheme() {
        XCTAssertThrowsError(try SSHRemoteURL(parse: "https://github.com/owner/repo.git"))
    }
}
