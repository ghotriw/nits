# Logging

All player logs go through `AppLog` (`NitsCore`). Each message is sent to:

- `os.Logger`, subsystem `com.nits`
- an in-memory buffer of the last 2000 entries, used by the log viewer
- `~/Library/Application Support/Nits/player.log`, written asynchronously

Messages below `AppLog.minimumLogLevel` are not formatted (the message is an `@autoclosure`).

## Logging from a host app

```swift
import NitsCore

AppLog.info(.host, "Playback session started")
AppLog.warning("Network", "Retrying range request")  // ad-hoc category
```

`LogCategory` is `ExpressibleByStringLiteral`. To get a typed category:

```swift
extension LogCategory {
    static let emby = LogCategory("YourCategoryName")
}
```

Levels: `debug`, `info`, `notice`, `warning`, `error`.

The default minimum level is `.debug` in Debug builds and `.info` in Release. To change it at runtime:

```swift
AppLog.minimumLogLevel = .debug
```

## Log viewer

```swift
import NitsKit

LogViewerWindowController.shared.show()
```

The menu command `PlayerCommands.LogConsoleMenuCommand()` binds it to ⌥⌘L. The viewer can filter by level and category, search, copy, export and clear the log (clearing also truncates `player.log`).

## Reading logs from the terminal

```bash
tail -f ~/Library/Application\ Support/Nits/player.log

log stream --predicate 'subsystem == "com.nits"' --level debug
log show --predicate 'subsystem == "com.nits"' --last 10m --info --debug
```
