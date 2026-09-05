# Wispr status bridge v2

Linux packages expose `com.criomos.wispr.status.v2` over private Unix sockets
under `$XDG_RUNTIME_DIR`: `wispr-flow-status-v2.sock` and
`wispr-flow-control-v2.sock` (mode `0600`). If the FHS Electron child loses the
variable, the app recovers the same user-owned private runtime directory at
`/run/user/<uid>`. Electron starts the app-owned bridge once at main-process
ready, before any dictation lifecycle transition. No helper acknowledgement,
keyboard event, transcript, or credential is exposed.

The upstream Status BrowserWindow stays hidden on Linux both when its ordinary
show path runs and when dictation-start visibility recovery runs. Noctalia is
the only status surface in the managed desktop integration.

Every status client immediately receives a newline-delimited JSON `snapshot`:
`contract`, `type`, `session_id`, `sequence`, `state`, `hands_free`, `capture`,
and `rms`.
`state` is `idle`, `recording`, `transcribing`, or `error`; only an optional
machine-safe error code may accompany `error`. A process start changes
`session_id`; each lifecycle transition increments `sequence`.

`capture` is `available` only while the recorder can supply a scalar meter;
then `rms` is a finite normalized value from `0` through `1`. `rms:0` is true
silence, whereas `capture:"unavailable",rms:null` means the capture path is
not available. Packets never carry samples, waveform data, or FFT bins.

The bridge republishes its current snapshot every second, below the consumer's
five-second stale threshold, so an unchanged recording remains live. The
authoritative lock mutator also publishes the current `hands_free` value.

The control socket accepts only `{contract,type:"control",id,command:"toggle_hands_free"}`.
It replies with `control_result`, `id`, `ok`, and `hands_free` on success. The
app starts from `Idle` or `Dismissed` and stops only when `Listening` is locked;
it publishes the resulting mode before replying. Use:

```
wispr-flow-status toggle-hands-free
```

For an AppImage use `Wispr-Flow.AppImage --toggle-hands-free`.

The bridge first binds exclusively and never unlinks a socket that accepts a
connection. Reclaiming a refused stale pathname has an unavoidable same-user
TOCTOU window: another process with the same UID can replace it between the
probe and unlink. Socket mode `0600` prevents other UIDs, but this is not a
same-UID security boundary; competing same-user launches are unsupported.
