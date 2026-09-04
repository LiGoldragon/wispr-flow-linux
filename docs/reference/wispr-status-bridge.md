# Wispr status bridge v1

Linux packages expose `com.criomos.wispr.status.v1` over private Unix sockets
under `$XDG_RUNTIME_DIR`: `wispr-flow-status-v1.sock` and
`wispr-flow-control-v1.sock` (mode `0600`). If the FHS Electron child loses the
variable, the app recovers the same user-owned private runtime directory at
`/run/user/<uid>`. Electron starts the app-owned bridge once at main-process
ready, before any dictation lifecycle transition. No helper acknowledgement,
keyboard event, transcript, or credential is exposed.

The upstream Status BrowserWindow stays hidden on Linux both when its ordinary
show path runs and when dictation-start visibility recovery runs. Noctalia is
the only status surface in the managed desktop integration.

Every status client immediately receives a newline-delimited JSON `snapshot`:
`contract`, `type`, `session_id`, `sequence`, `state`, and `hands_free`.
`state` is `idle`, `recording`, `transcribing`, or `error`; only an optional
machine-safe error code may accompany `error`. A process start changes
`session_id`; each lifecycle transition increments `sequence`.

The control socket accepts only `{contract,type:"control",id,command:"toggle_hands_free"}`.
It replies with `control_result`, `id`, `ok`, and `hands_free` on success. The
app invokes its own start/stop hands-free actions before replying. Use:

```
wispr-flow-status toggle-hands-free
```

For an AppImage use `Wispr-Flow.AppImage --toggle-hands-free`.

The bridge first binds exclusively and never unlinks a socket that accepts a
connection. Reclaiming a refused stale pathname has an unavoidable same-user
TOCTOU window: another process with the same UID can replace it between the
probe and unlink. Socket mode `0600` prevents other UIDs, but this is not a
same-UID security boundary; competing same-user launches are unsupported.
