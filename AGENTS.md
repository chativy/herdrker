# Repository Guidelines

## Product Overview

Herdrker is a macOS menu-bar-only application for observing and controlling tasks managed by `herdr-core` (`hc`). The app has no Dock icon or main window. All project documentation and user-facing UI text must be written in English, regardless of the language used for discussion.

## Functional Requirements

### Menu bar

- Use the official Herdr icon in the macOS status bar.
- Show a prominent red dot beside the icon whenever `hc ls --all --json` returns at least one task, including finished tasks. Hide the dot when no tasks exist.
- Show the local machine first, followed by configured remote hosts. Each host opens a submenu containing only that host's tasks.
- Refresh the task and host lists when the menu opens and periodically while the app is running.
- Provide top-level actions for creating a task and adding a host.

### Tasks

- A task dialog must let the user choose a host and enter an optional task name, shell command, and working directory. When the command is blank, omit it so Herdr Core starts that host's login shell. Default a local task with no working directory to the user's home folder. Create the task with `hc run --bg --no-parent`, passing `--on <host>` for remote hosts. Do not inject shell color variables from the app.
- After a task is created successfully, immediately open its terminal and attach to the new task.
- Supply the creation client's terminal identity (`TERM`, `TERM_PROGRAM`, and `COLORTERM`) because Herdr Core fixes it before the task is attached. Do not inject `CLICOLOR`; shell color preferences belong in the user's shell configuration.
- Assign global hotkeys to the first 10 tasks in menu order using the configured modifier prefix plus 1 through 9, then 0. The default prefix is Command+Option. The top-level **Assign Hotkey…** menu item must capture a modifier prefix from the keyboard and apply it to all task shortcuts. Invoking a hotkey must focus the tracked task window or open and attach it when no tracked window exists.
- Use the configured prefix for New Task (`N`), Refresh (`R`), and Quit (`Q`) as global shortcuts. Place **Assign Hotkey…** immediately above **Quit Herdrker**.
- A live task opens interactively in Ghostty when installed at `/Applications/Ghostty.app`; otherwise, open Terminal. Use Ghostty's AppleScript `new window with configuration` command so all task windows belong to one Ghostty application instance rather than launching new application instances.
- Resolve the selected task with `hc get <address> --json`, then open and attach with all available history. Track Ghostty windows by the stable AppleScript window ID so a hotkey can focus the specific existing window.
- A finished task opens its final screen with `hc read <address>` through `less -S` so long lines preserve their original width. The terminal process must ignore task input. Do not call `attach` for finished tasks because Herdr Core rejects it.
- A finished task's submenu must offer **View Final Screen** and **Remove Task**. Remove only finished tasks, using `hc rm <address>`.
- Display task state clearly. Treat Herdr's `finished` state as stopped.

### Hosts

- A host dialog must collect an optional display name, an SSH target such as `user@example.com` or an SSH config alias, and an **Install herdr-core if missing** option.
- Add hosts with `hc machine add`, passing `--name` and `--install` when selected. Never store SSH passwords or private keys in the app.

## Technical Architecture

Implement the app in Swift 6 with AppKit status items and SwiftUI dialogs, built with Swift Package Manager. Keep Herdr Core access behind an injectable client that invokes `hc` as a child process and decodes JSON defensively. Never construct shell command strings for user input; pass arguments to `Process` directly.

The executable should locate `herdr-core` from `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin`. Report command failures through native alerts and refresh the menu after mutations.

## Project Structure

- `Sources/Herdrker/`: application, menu, dialog, model, and CLI client code.
- `Tests/HerdrkerTests/`: unit tests, including JSON decoding and command construction.
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
