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
            "parent": "t4",
            "created_ms": 2000
          }
        ]
        """.utf8)

        let tasks = try HerdrJSON.taskList(from: data)

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].displayName, "build")
        XCTAssertTrue(tasks[0].isFinished)
        XCTAssertEqual(tasks[1].machine, "mini")
        XCTAssertEqual(tasks[1].parent, "t4")
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
                "run", "--bg", "--json", "--no-parent",
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
                "run", "--bg", "--json", "--no-parent", "--on", "mini"
            ]
        )
    }

    func testParentedTaskUsesParentInsteadOfNoParent() {
        let request = NewTaskRequest(
            host: nil,
            name: "child",
            command: nil,
            workingDirectory: "/Users/example",
            parent: "t1"
        )

        let arguments = HerdrCoreCommand.createTask(request).arguments

        XCTAssertTrue(arguments.contains("--parent"))
        XCTAssertTrue(arguments.contains("t1"))
        XCTAssertFalse(arguments.contains("--no-parent"))
    }

    func testTaskPassesHerdrLocationLabels() {
        let request = NewTaskRequest(
            host: "o",
            name: "child",
            command: "sleep 100",
            workingDirectory: "/srv/app",
            parent: "o/t1",
            herdrSpaceID: "o/sp-remote",
            herdrTabID: "o/tb-deploy",
            whereLabel: "herdrker / review"
        )

        XCTAssertEqual(
            HerdrCoreCommand.createTask(request).arguments,
            [
                "run", "--bg", "--json",
                "--parent", "o/t1",
                "--on", "o",
                "--name", "child",
                "--cwd", "/srv/app",
                "--label", "where=herdrker / review",
                "--label", "herdr.space=o/sp-remote",
                "--label", "herdr.tab=o/tb-deploy",
                "--", "sleep 100"
            ]
        )
    }

    func testTaskHierarchyNestsChildrenInParentOrder() {
        let parent = HerdrTask(
            address: "t1",
            name: "parent",
            title: nil,
            machine: nil,
            state: "live",
            status: nil,
            createdAt: nil
        )
        let child = HerdrTask(
            address: "t2",
            name: "child",
            title: nil,
            machine: nil,
            state: "live",
            status: nil,
            createdAt: nil,
            parent: "t1"
        )
        let grandchild = HerdrTask(
            address: "t3",
            name: "grandchild",
            title: nil,
            machine: nil,
            state: "live",
            status: nil,
            createdAt: nil,
            parent: "t2"
        )

        let hierarchy = HerdrModel.taskHierarchy(
            tasks: [grandchild, parent, child]
        )

        XCTAssertEqual(hierarchy.map(\.task.address), ["t1"])
        XCTAssertEqual(hierarchy[0].children.map(\.task.address), ["t2"])
        XCTAssertEqual(
            hierarchy[0].children[0].children.map(\.task.address),
            ["t3"]
        )
        XCTAssertEqual(
            HerdrModel.flattened(hierarchy).map(\.address),
            ["t1", "t2", "t3"]
        )
    }

    func testHerdrAppLocationsAreSelectableSpaceTabPairs() throws {
        let data = Data("""
        {
          "spaces": [
            {
              "id": "sp-local",
              "name": "herdrker",
              "machine": null,
              "tabs": [
                {"id": "tb-review", "name": "review"},
                {"id": "tb-build", "name": "build"}
              ]
            },
            {
              "id": "o/sp-remote",
              "name": "service",
              "machine": "o",
              "tabs": [
                {"id": "o/tb-deploy", "name": "deploy"}
              ]
            }
          ]
        }
        """.utf8)

        let locations = try HerdrModel.locations(from: data)

        XCTAssertEqual(locations.count, 3)
        XCTAssertEqual(locations[0].label, "herdrker / review")
        XCTAssertEqual(locations[0].hostID, HerdrModel.localHostID)
        XCTAssertEqual(locations[2].label, "service / deploy")
        XCTAssertEqual(locations[2].hostID, "o")
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
