# howl-pty

Native Zig PTY ownership for `howl-headless`.

The package owns one child process group, PTY descriptors, nonblocking
read/write/wait, explicit wake, resize delivery, typed signals, and cleanup.
It contains no ABI or Session orchestration.

```sh
zig build check
zig build test
```
