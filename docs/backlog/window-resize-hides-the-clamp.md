---
worth: later
where: agterm/Control/ControlServer+WindowCommands.swift:111
added: 2026-09-06
---
# window resize answers a bare id, so a clamped request looks honoured

`window.resize` clamps into `[minSize, visibleFrame]` and replies with the window id alone. A caller
asking for 3000pt of height gets `ok` and has to run `window list` to learn it got 1084. `session.resize`
already echoes the applied value for the same reason (SocketClient.swift:243). Echo the applied width and
height in the result, and print them from the CLI. Surfaced while reviewing discussion #559.
