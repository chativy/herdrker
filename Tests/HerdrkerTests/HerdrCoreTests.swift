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

    func testMoveTaskSetsHerdrSpaceAndTabLabels() {
        XCTAssertEqual(
            HerdrCoreCommand.moveTask(
                "o/t3",
                spaceID: "sp-destination",
                tabID: "tb-destination"
            ).arguments,
            [
                "label", "--json", "o/t3",
                "herdr.space=sp-destination",
                "herdr.tab=tb-destination"
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
                {
                  "id": "tb-review",
                  "name": "review",
                  "terminals": [{"terminal": "t1"}]
                },
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
        XCTAssertEqual(locations[0].terminalAddresses, ["t1"])
        XCTAssertEqual(locations[2].label, "service / deploy")
        XCTAssertEqual(locations[2].hostID, "o")
    }

    func testDuplicateLocationLabelsIncludeShortIdentifiers() {
        let locations = [
            HerdrLocationChoice(
                spaceID: "sp1df1d883228ab",
                tabID: "tb93f21820b3",
                spaceName: "~",
                tabName: "1",
                machine: nil
            ),
            HerdrLocationChoice(
                spaceID: "sp74eb7204eb2f",
                tabID: "tb2e60d44990",
                spaceName: "~",
                tabName: "1",
                machine: nil
            )
        ]

        let labels = HerdrModel.locationLabels(for: locations)

        XCTAssertEqual(
            labels[locations[0].id],
            "~ / 1 [sp1df1d8/tb93f218]"
        )
        XCTAssertEqual(
            labels[locations[1].id],
            "~ / 1 [sp74eb72/tb2e60d4]"
        )
    }

    func testRemoteLocationUsesMachineLocalCoreIDs() {
        let location = HerdrLocationChoice(
            spaceID: "o/sp-remote",
            tabID: "o/tb-deploy",
            spaceName: "service",
            tabName: "deploy",
            machine: "o"
        )

        XCTAssertEqual(location.coreSpaceID, "sp-remote")
        XCTAssertEqual(location.coreTabID, "tb-deploy")
    }

    func testMoveTargetsGroupBySpaceAndDisambiguateTabs() {
        let locations = [
            HerdrLocationChoice(
                spaceID: "sp-one",
                tabID: "tb-one",
                spaceName: "~",
                tabName: "1",
                machine: nil
            ),
            HerdrLocationChoice(
                spaceID: "sp-one",
                tabID: "tb-two",
                spaceName: "~",
                tabName: "1",
                machine: nil
            ),
            HerdrLocationChoice(
                spaceID: "sp-two",
                tabID: "tb-three",
                spaceName: "~",
                tabName: "2",
                machine: nil
            )
        ]

        let spaces = HerdrModel.spaces(from: locations)
        let spaceLabels = HerdrModel.spaceLabels(for: spaces)
        let tabLabels = HerdrModel.tabLabels(
            for: locations.filter { $0.spaceID == "sp-one" }
        )

        XCTAssertEqual(spaces.map(\.id), ["sp-one", "sp-two"])
        XCTAssertEqual(spaceLabels["sp-one"], "~ [sp-one]")
        XCTAssertEqual(spaceLabels["sp-two"], "~ [sp-two]")
        XCTAssertEqual(tabLabels["sp-one/tb-one"], "1 [tb-one]")
        XCTAssertEqual(tabLabels["sp-one/tb-two"], "1 [tb-two]")
    }

    func testTaskLocationGroupsSeparatePlacedAndUnplacedTasks() {
        func task(_ address: String, parent: String? = nil) -> HerdrTask {
            HerdrTask(
                address: address,
                name: address,
                title: nil,
                machine: nil,
                state: "live",
                status: nil,
                createdAt: nil,
                parent: parent
            )
        }

        let tasks = [
            task("t1"),
            task("t2", parent: "t1"),
            task("t3"),
            task("t4")
        ]
        let locations = [
            HerdrLocationChoice(
                spaceID: "sp-one",
                tabID: "tb-one",
                spaceName: "~",
                tabName: "1",
                machine: nil,
                terminalAddresses: ["t1", "t2"]
            ),
            HerdrLocationChoice(
                spaceID: "sp-two",
                tabID: "tb-two",
                spaceName: "work",
                tabName: "2",
                machine: nil,
                terminalAddresses: ["t3"]
            )
        ]

        let groups = HerdrModel.taskLocationGroups(
            tasks: tasks,
            locations: locations
        )
        let unplaced = HerdrModel.unplacedTasks(
            tasks: tasks,
            locations: locations
        )

        XCTAssertEqual(groups.map(\.location.id), [
            "sp-one/tb-one",
            "sp-two/tb-two"
        ])
        XCTAssertEqual(groups[0].tasks.map(\.address), ["t1", "t2"])
        XCTAssertEqual(groups[1].tasks.map(\.address), ["t3"])
        XCTAssertEqual(unplaced.map(\.address), ["t4"])
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
