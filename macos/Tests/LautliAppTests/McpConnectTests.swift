import Foundation
import XCTest
@testable import LautliApp

final class McpConnectTests: XCTestCase {
    private let connect = McpConnect(paths: AppPaths(
        support: URL(fileURLWithPath: "/Users/o'neil/Library/Application Support/lautli"),
        workerSource: URL(fileURLWithPath: "/Applications/lautli.app/Contents/Resources/worker-src")
    ))

    func testClaudeCodeCommandQuotesPathsWithSpacesAndApostrophes() {
        XCTAssertEqual(
            connect.claudeCodeCommand,
            "claude mcp add --scope user lautli -- '/Users/o'\\''neil/Library/Application Support/lautli/runtime/python/bin/python3' '/Applications/lautli.app/Contents/Resources/worker-src/worker/lautli_worker/mcp_server.py'"
        )
    }

    func testCodexConfigIsATomlTable() {
        XCTAssertEqual(
            connect.codexConfig,
            "[mcp_servers.lautli]\ncommand = \"/Users/o'neil/Library/Application Support/lautli/runtime/python/bin/python3\"\nargs = [\"/Applications/lautli.app/Contents/Resources/worker-src/worker/lautli_worker/mcp_server.py\"]\n"
        )
    }

    func testJsonConfigDecodesToTheMcpServersShape() throws {
        let object = try JSONSerialization.jsonObject(with: Data(connect.jsonConfig.utf8)) as? [String: [String: [String: Any]]]
        let server = try XCTUnwrap(object?["mcpServers"]?["lautli"])
        XCTAssertEqual(server["command"] as? String, connect.python)
        XCTAssertEqual(server["args"] as? [String], [connect.script])
    }

    func testIsReadyOnlyOnceThePythonRuntimeExists() {
        XCTAssertFalse(connect.isReady)
    }
}
