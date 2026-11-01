import Foundation
import XCTest
@testable import Herdrker

final class HerdrCoreTests: XCTestCase {
    func testTaskListDecodesLocalAndRemoteTasks() throws {
        let data = Data("""
        [
          {
            "address": "t4",
            "name": "build",
            "title": "Build project",
            "state": "finished",
            "status": "done",
            "created_ms": 1000
          },
          {
            "address": "mini/t7",
            "title": "Review",
            "state": "live",
            "status": "working",
            "created_ms": 2000
          }
        ]
        """.utf8)

        let tasks = try HerdrJSON.taskList(from: data)

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].displayName, "build")
        XCTAssertTrue(tasks[0].isFinished)
        XCTAssertEqual(tasks[1].machine, "mini")
        XCTAssertEqual(tasks[1].stateLabel, "Working")
    }

    func testHostListIgnoresTemporaryMachinesWhenGrouping() throws {
        let hostData = Data("""
        [
          {"name": "mini", "target": "dev@mini"},
          {"name": "sandbox", "temporary": true}
        ]
        """.utf8)
        let taskData = Data("""
        [
          {"address": "t1", "name": "local shell", "state": "live"},
          {"address": "mini/t2", "name": "remote task", "state": "live"}
        ]
        """.utf8)

        let hosts = try HerdrJSON.hostList(from: hostData)
        let tasks = try HerdrJSON.taskList(from: taskData)
        let groups = HerdrModel.groups(hosts: hosts, tasks: tasks)

        XCTAssertEqual(groups.map(\.host.name), [HerdrModel.localHostID, "mini"])
        XCTAssertEqual(groups[0].tasks.map(\.displayName), ["local shell"])
        XCTAssertEqual(groups[1].tasks.map(\.displayName), ["remote task"])
    }

    func testCreateTaskBuildsSafeArguments() {
        let request = NewTaskRequest(
            host: "mini",
            name: "review",
            command: "echo $HOME && claude",
            workingDirectory: "/srv/app"
        )

        XCTAssertEqual(
            HerdrCoreCommand.createTask(request).arguments,
            [
                "run", "--bg", "--no-parent", "--json",
                "--on", "mini",
                "--name", "review",
                "--cwd", "/srv/app",
                "--", "echo $HOME && claude"
            ]
        )
    }

    func testAddHostBuildsInstallArguments() {
        let request = NewHostRequest(
            name: "devbox",
            target: "user@example.com",
            installCore: true
        )

        XCTAssertEqual(
            HerdrCoreCommand.addHost(request).arguments,
            [
                "machine", "add", "--json",
                "--name", "devbox",
                "--install",
                "--", "user@example.com"
            ]
        )
    }

    func testBlankTaskCommandStartsTheDefaultShell() {
        let request = NewTaskRequest(
            host: "mini",
            name: nil,
            command: nil,
            workingDirectory: nil
        )

        XCTAssertEqual(
            HerdrCoreCommand.createTask(request).arguments,
            [
                "run", "--bg", "--no-parent", "--json", "--on", "mini",
                "--", HerdrCoreCommand.loginShellCommand
            ]
        )
        XCTAssertTrue(HerdrCoreCommand.loginShellCommand.contains("CLICOLOR=1"))
        XCTAssertTrue(HerdrCoreCommand.loginShellCommand.contains("-l"))
    }

    func testTaskDetailsIncludeTerminalGeometry() throws {
        let data = Data("""
        {
          "address": "t2",
          "cols": 200,
          "rows": 120,
          "state": "live"
        }
        """.utf8)

        let task = try HerdrJSON.task(from: data)

        XCTAssertEqual(task.cols, 200)
        XCTAssertEqual(task.rows, 120)
        XCTAssertEqual(
            HerdrCoreCommand.task("t2").arguments,
            ["get", "t2", "--json"]
        )
    }

    func testLocalDefaultWorkingDirectoryIsHome() {
        let home = URL(fileURLWithPath: "/Users/example")

        XCTAssertEqual(
            HerdrModel.defaultWorkingDirectory(
                hostID: HerdrModel.localHostID,
                homeDirectory: home
            ),
            "/Users/example"
        )
        XCTAssertNil(
            HerdrModel.defaultWorkingDirectory(
                hostID: "remote",
                homeDirectory: home
            )
        )
    }
}
