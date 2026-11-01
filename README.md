# Herdrker

Herdrker is a macOS menu-bar controller for
[herdr-core](https://github.com/herdrdev/herdr-core). It groups tasks by host,
opens live tasks in Ghostty or Terminal, and shows finished tasks as read-only
final screens.

## Requirements

- macOS 14 or later
- `herdr-core` available as `herdr-core` or `hc`
- Ghostty (optional; Terminal is the fallback)

## Build and Run

```sh
swift test
./scripts/build-app.sh
open build/Herdrker.app
```

Set `HERDRKER_CONFIGURATION=debug` for a faster local build. The bundle is
signed with a valid local Apple Development identity. Set
`HERDRKER_SIGN_IDENTITY` to choose a specific signing certificate.

The status icon displays a red dot whenever Herdr Core has at least one task.
Open the menu to create a task, add an SSH host, attach to a live task, or view
and remove a stopped task. Leaving a task's command blank starts the selected
host's login shell; local tasks default to the user's home directory.
Each task's submenu includes **Rename Task…** for setting a Herdrker-local
display name.

Herdr Core keeps 5 MiB of scrollback per live terminal by default. Set
`history_mb` in `~/.config/herdr-core/config.toml` to change that byte budget.
New values apply to terminals created afterward. Herdrker restores all history
that Herdr Core has retained when attaching.
