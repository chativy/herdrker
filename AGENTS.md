# Repository Guidelines

## Product Overview

Herdrker is a macOS menu-bar-only application for observing and controlling tasks managed by `herdr-core` (`hc`) and Rex. The app has no Dock icon or main window. All project documentation and user-facing UI text must be written in English, regardless of the language used for discussion.

## Functional Requirements

### Menu bar

- Use the official Herdr icon in the macOS status bar.
- Show a prominent red dot beside the icon whenever either backend has at least one task. Herdr finished tasks count as tasks.
- Show separate top-level **Herdr** and **Rex** sections only when that backend is installed and currently has at least one task. Within each, show the local machine first, followed by configured remote hosts. Keep installed backends available in New Task and Add Host even when their menu section is hidden.
- When exactly one backend has tasks, promote its host items directly to the menu root and omit the backend wrapper level. Use backend wrappers only when both Herdr and Rex have tasks.
- Refresh the task and host lists when the menu opens and periodically while the app is running.
- Provide top-level actions for creating a task and adding a host.

### Tasks

- A task dialog must let the user choose a host, optional live parent task, optional task name, existing Herdr space/tab location, shell command, and working directory. Read locations from `herdr-app ls` and offer only locations on the selected host. Offer only live parent tasks on the selected host. When no parent is selected, preserve the current independent behavior with `--no-parent`; otherwise use `--parent <address>` without `--no-parent`. Pass a selected location through `--label "where=<space> / <tab>"` for CLI display and through `--label "herdr.space=<space-id>"` plus `--label "herdr.tab=<tab-id>"` so the Herdr app places the terminal in that tab. When the command is blank, omit it so Herdr Core starts that host's login shell. Default a local task with no working directory to the user's home folder. Create the task with `hc run --bg`, passing `--on <host>` for remote hosts. Do not inject shell color variables from the app.
- After a task is created successfully, immediately open its terminal and attach to the new task.
- Supply the creation client's terminal identity (`TERM`, `TERM_PROGRAM`, and `COLORTERM`) because Herdr Core fixes it before the task is attached. Do not inject `CLICOLOR`; shell color preferences belong in the user's shell configuration.
- Assign global hotkeys to up to 33 tasks across the visible Herdr and Rex menu order using the configured modifier prefix plus 1 through 9, 0, then a through z except n, r, and q. Keep n, r, and q reserved for New Task, Refresh, and Quit. The default prefix is Command+Option. The top-level **Assign Hotkey…** menu item must capture a modifier prefix from the keyboard and apply it to all task shortcuts. Invoking a Herdr hotkey must focus or attach its viewer; invoking a Rex hotkey must focus its block and activate Rex.
- Register every candidate shortcut independently. Exclude any key that macOS or another application already owns, compact successful task keys into menu order, hide shortcuts for failed registrations, and report the failed key combinations after assignment.
- AppKit hides native key-equivalent text on menu items that have submenus. Measure the widest task title in each menu, then append shortcuts through a shared left-aligned tab stop 16 points after that width. Trim the final shortcut advance by 8 points to tighten the gap before the native submenu arrow while retaining Carbon global-hotkey behavior.
- Use the configured prefix for New Task (`N`), Refresh (`R`), and Quit (`Q`) as global shortcuts. Place **Assign Hotkey…** immediately above **Quit Herdrker**.
- A live task opens interactively in Ghostty when installed at `/Applications/Ghostty.app`; otherwise, open Terminal. Use Ghostty's AppleScript `new window with configuration` command so all task windows belong to one Ghostty application instance rather than launching new application instances.
- Resolve the selected task with `hc get <address> --json`, then open and attach with all available history. Track Ghostty windows by the stable AppleScript window ID so a hotkey can focus the specific existing window.
- A finished task opens its final screen with `hc read <address>` through `less -S` so long lines preserve their original width. The terminal process must ignore task input. Do not call `attach` for finished tasks because Herdr Core rejects it.
- A finished task's submenu must offer **View Final Screen** and **Remove Task**. Remove only finished tasks, using `hc rm <address>`, without a confirmation dialog.
- Display task state clearly. Treat Herdr's `finished` state as stopped.
- Within each host submenu, group placed tasks as **Space → Tab → Task** using `herdr-app ls`. Keep parent-child relationships nested within each tab group. Tasks without a Herdr location remain directly under the host. Keep hotkey numbering in visible preorder, with located groups first and unplaced tasks afterward.
- Omit redundant Herdr menu levels: a space containing exactly one task is shown directly under the host, and a space with exactly one tab shows its tasks directly under the space. Use the tab level only when a space has multiple tabs and more than one task.
- Map `herdr-app ls` tab terminals back to task addresses. Show the selected space/tab beside each placed task in host menus. When multiple locations have the same space/tab name, append short space and tab IDs to both task labels and New Task picker entries so they remain distinguishable.
- Show **Move to** only when at least one other existing location is available on the task's host; include destination space submenus and, within each, selectable tabs. Exclude the task's current tab. A live leaf task with no move targets remains directly selectable. Move by parking the existing pane, setting `herdr.space` and `herdr.tab` through `hc label`, then waiting for the Herdr app to adopt the terminal in the selected tab. Restore the previous location if the move fails.

### Hosts

- The Add Host dialog must select Herdr or Rex first.
- Offer only installed backends in Add Host and New Task. Persist the last selected backend in UserDefaults and fall back to the first installed backend when it is unavailable.
- Herdr hosts collect an optional display name, an SSH target such as `user@example.com` or an SSH config alias, and an **Install herdr-core if missing** option. Add them with `hc machine add`, passing `--name` and `--install` when selected.
- Rex hosts collect a required label, SSH/HTTPS-or-Tailscale/Unix-socket endpoint, optional icon, and reachability-check option. Add them with `rex hosts add`.
- Never attempt to install Rex Server automatically. After adding, run `rex hosts check` when selected and keep the host registered if it is temporarily unreachable. Show actionable installation guidance instead of running a remote installer.
- Never store SSH passwords or private keys in the app.

### Rex

- Locate the `rex` CLI from `PATH`, `/Applications/Rex.app`, `/Applications/Rex Beta.app`, or the matching user Applications folders.
- Read hosts with `rex hosts --json`, sessions with `rex ls --json`, and terminal blocks with `rex session inspect <session> --json`.
- Present Rex tasks as Host → Session → Window → Block.
- Open a Rex block with `rex block focus` and activate the Rex app. Support block rename and close from the task submenu.
- Create Rex tasks with the control API using `session.create` or `session.new_window`, the `com.superlogical.terminal.shell` flavor, cwd/label options, and `initial_input` when a command is supplied. A blank command must start Rex's default shell.

## Technical Architecture

Implement the app in Swift 6 with AppKit status items and SwiftUI dialogs, built with Swift Package Manager. Keep Herdr Core access behind an injectable client that invokes `hc` as a child process and decodes JSON defensively. Never construct shell command strings for user input; pass arguments to `Process` directly.

Keep Rex access behind an injectable `RexClient` that invokes the bundled or installed `rex` CLI with argument arrays. Decode host/session JSON defensively. Do not require the third-party `rex-attach` client.

The executable should locate `herdr-core` from `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin`. Report command failures through native alerts and refresh the menu after mutations.

Herdrker may itself be launched from a Herdr Core task. Remove inherited `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, `HC_SCOPE`, and `HC_RUNTIME` from the app process, `hc` children, and newly created terminal commands. Preserve `HC_SESSION` and explicit `HC_SOCKET` configuration. This prevents self-attach loops and prevents task cleanup from sweeping Herdrker.

## Project Structure

- `Sources/Herdrker/`: application, menu, dialog, model, and CLI client code.
- `Tests/HerdrkerTests/`: unit tests, including Herdr/Rex JSON decoding and command construction.
- `Resources/`: official Herdr icon, bundle metadata, and asset provenance.
- `scripts/build-app.sh`: release build and `.app` bundle assembly.

## Build, Test, and Development

```sh
swift build
swift test
./scripts/build-app.sh
open build/Herdrker.app
```

The first command compiles the package, the second runs tests, and the last two create and launch the menu-bar app. The packaging script must sign with a valid Apple identity; ad-hoc signing is not permitted. Set `HERDRKER_SIGN_IDENTITY` to select a specific certificate.

## Coding Style & Testing

Use four-space Swift indentation, standard Swift API naming, small focused types, and `async` APIs for process and UI work. Keep UI changes on the main actor. Use XCTest for model parsing, command argument construction, host grouping, and task state mapping. Tests should describe observable behavior and run with `swift test`.

## Commit & Pull Request Guidelines

Use concise imperative commit subjects such as `Add task creation dialog`, matching the existing history. Pull requests should summarize behavior, list verification commands, link related issues, and include screenshots for menu or dialog changes.

## Security & Configuration

Do not commit credentials, SSH keys, logs, build products, or machine-specific configuration. Depend on the user's existing SSH configuration and Keychain/agent setup.

Herdr Core retains 5 MiB of scrollback per live terminal by default. Its `history_mb` setting changes this byte budget for newly created terminals; terminal-created existing history is not expanded retroactively.
