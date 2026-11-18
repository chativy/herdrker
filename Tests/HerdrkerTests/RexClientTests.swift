import Foundation
import XCTest
@testable import Herdrker

final class RexClientTests: XCTestCase {
    func testHostListIncludesLocalAndRemoteHosts() throws {
        let data = Data("""
        {
          "home": {
            "endpoint": "unix:///tmp/rex.sock",
            "this_machine": true,
            "reached": true
          },
          "hosts": [
            {
              "label": "studio",
              "endpoints": [
                "ssh://user@studio",
                "https://studio.tailnet.ts.net"
              ]
            }
          ]
        }
        """.utf8)

        let hosts = try RexClient.hosts(from: data)

        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(hosts[0].displayName, "This Mac")
        XCTAssertTrue(hosts[0].isLocal)
        XCTAssertEqual(hosts[1].label, "studio")
        XCTAssertEqual(hosts[1].endpoints.count, 2)
        XCTAssertFalse(hosts[1].isLocal)
    }

    func testSessionListDecodesRexSessions() throws {
        let data = Data("""
        {
          "sessions": [
            {
              "session_id": "session:one",
              "label": "first one"
            },
            {
              "session_id": "session:two",
              "label": "second one"
            }
          ]
        }
        """.utf8)

        let sessions = try RexClient.sessions(from: data)

        XCTAssertEqual(sessions.map(\.id), ["session:one", "session:two"])
        XCTAssertEqual(sessions.map(\.label), ["first one", "second one"])
    }

    func testSessionViewCollectsOnlyTerminalBlocks() throws {
        let host = RexHost(
            label: "",
            displayName: "This Mac",
            endpoints: [],
            isLocal: true
        )
        let fallback = RexSessionInfo(
            id: "session:one",
            label: "fallback",
            windows: []
        )
        let data = Data("""
        {
          "label": "work",
          "windows": [
            {
              "window_id": "window:one",
              "label": "editor",
              "layers": [
                {
                  "blocks": [
                    {
                      "block_id": "block:terminal",
                      "label": "shell",
                      "creator_name": "com.superlogical.terminal"
                    },
                    {
                      "block_id": "block:other",
                      "label": "files",
                      "creator_name": "example.files"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """.utf8)

        let session = try RexClient.sessionInfo(
            from: data,
            host: host,
            fallbackSession: fallback
        )

        XCTAssertEqual(session.label, "work")
        XCTAssertEqual(session.windows.count, 1)
        XCTAssertEqual(session.windows[0].label, "editor")
        XCTAssertEqual(
            session.windows[0].blocks.map(\.blockID),
            ["block:terminal"]
        )
    }

    func testHostCheckRecognizesReachability() throws {
        let data = Data("""
        {
          "hosts": [
            {
              "label": "studio",
              "status": "reachable",
              "detail": "answered by studio.tailnet.ts.net"
            }
          ]
        }
        """.utf8)

        let check = try RexClient.hostCheck(label: "studio", from: data)

        XCTAssertTrue(check.reachable)
        XCTAssertEqual(check.label, "studio")
    }
}
