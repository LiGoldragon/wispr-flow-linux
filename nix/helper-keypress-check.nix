{
  lib,
  pkgs,
  runtimeInputs,
  stdenv,
  writeText,
}:
let
  uinputEmitter = stdenv.mkDerivation {
    pname = "wispr-flow-uinput-keypress-emitter";
    version = "1";
    dontUnpack = true;
    src = writeText "uinput-keypress-emitter.c" ''
      #include <errno.h>
      #include <fcntl.h>
      #include <linux/input-event-codes.h>
      #include <linux/uinput.h>
      #include <stdio.h>
      #include <string.h>
      #include <sys/ioctl.h>
      #include <unistd.h>

      static int emit_key(int fd, unsigned short code, int value) {
        struct input_event event = {
          .type = EV_KEY,
          .code = code,
          .value = value,
        };
        struct input_event sync = { .type = EV_SYN, .code = SYN_REPORT };
        return write(fd, &event, sizeof(event)) == sizeof(event)
          && write(fd, &sync, sizeof(sync)) == sizeof(sync)
          ? 0
          : -1;
      }

      int main(void) {
        int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
        if (fd < 0) {
          perror("open /dev/uinput");
          return 1;
        }
        if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0
          || ioctl(fd, UI_SET_KEYBIT, KEY_LEFTCTRL) < 0
          || ioctl(fd, UI_SET_KEYBIT, KEY_LEFTMETA) < 0
          || ioctl(fd, UI_SET_KEYBIT, KEY_A) < 0
          || ioctl(fd, UI_SET_KEYBIT, KEY_Z) < 0) {
          perror("configure uinput keyboard");
          return 1;
        }
        struct uinput_setup setup = {
          .id = { .bustype = BUS_USB, .vendor = 0xfeed, .product = 0x0101 },
          .name = "wispr-flow-keypress-witness",
        };
        if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
          perror("create uinput keyboard");
          return 1;
        }
        puts("READY");
        fflush(stdout);
        char command[8] = { 0 };
        if (fgets(command, sizeof(command), stdin) == NULL
          || strcmp(command, "GO\n") != 0) {
          fprintf(stderr, "expected GO command\n");
          return 1;
        }
        if (emit_key(fd, KEY_LEFTCTRL, 1) != 0
          || emit_key(fd, KEY_LEFTMETA, 1) != 0
          || emit_key(fd, KEY_LEFTMETA, 0) != 0
          || emit_key(fd, KEY_LEFTCTRL, 0) != 0) {
          perror("emit key sequence");
          return 1;
        }
        while (fgets(command, sizeof(command), stdin) != NULL) {
        }
        ioctl(fd, UI_DEV_DESTROY);
        close(fd);
        return 0;
      }
    '';
    nativeBuildInputs = [ stdenv.cc ];
    buildPhase = ''
      $CC -O2 -Wall -Wextra -Werror "$src" -o uinput-keypress-emitter
    '';
    installPhase = ''
      install -Dm755 uinput-keypress-emitter "$out/bin/uinput-keypress-emitter"
    '';
  };

  witness = writeText "helper-keypress-witness.py" ''
    import json
    import os
    import re
    import subprocess
    import sys


    def fail(message):
        raise AssertionError(message)


    def decode_frame(raw):
        if not raw.startswith(b"{\n  "):
            fail(f"frame is not pretty JSON: {raw!r}")
        if b"|" in raw:
            fail(f"unescaped delimiter in frame: {raw!r}")
        return json.loads(raw.decode("utf-8").replace("+2", "|").replace("+1", "+"))


    helper_path, emitter_path = sys.argv[1:]
    emitter = subprocess.Popen(
        [emitter_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if emitter.stdout.readline().strip() != "READY":
        fail(emitter.stderr.read())

    fd3_read, fd3_write = os.pipe()
    helper = subprocess.Popen(
        ["/bin/sh", "-c", 'exec 3>&1; exec "$1"', "sh", helper_path],
        stdin=subprocess.PIPE,
        stdout=fd3_write,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "RUST_LOG": "info"},
    )
    os.close(fd3_write)

    while True:
        line = helper.stderr.readline()
        if not line:
            fail(
                f"helper exited ({helper.poll()}) before evdev capture: "
                + helper.stderr.read()
            )
        if "key capture: evdev (/dev/input)" in line:
            break

    emitter.stdin.write("GO\n")
    emitter.stdin.flush()

    frames = []
    buffered = b""
    while len(frames) < 4:
        chunk = os.read(fd3_read, 4096)
        if not chunk:
            fail("fd3 closed before four KeypressEvent frames")
        buffered += chunk
        while b"|" in buffered:
            raw, buffered = buffered.split(b"|", 1)
            frames.append(decode_frame(raw))

    expected = [
        ("key_event_press", 162, 1),
        ("key_event_press", 91, 2),
        ("key_event_release", 91, 3),
        ("key_event_release", 162, 4),
    ]
    observed = []
    for frame in frames:
        request = frame.get("HelperAPIRequest")
        if set(request) != {"KeypressEvent", "uuid"}:
            fail(f"unexpected helper envelope: {frame!r}")
        keypress = request["KeypressEvent"]["payload"]
        observed.append((keypress["eventType"], keypress["key"], keypress["index"]))
        if keypress.get("inputType") != "keyboard":
            fail(f"unexpected input type: {keypress!r}")
    if observed != expected:
        fail(f"KeypressEvent sequence mismatch: expected {expected!r}, got {observed!r}")
    for position, frame in enumerate(frames, start=1):
        uuid = frame["HelperAPIRequest"]["uuid"]
        if not re.fullmatch(rf"kp-[0-9]+-{position}", uuid):
            fail(f"unexpected KeypressEvent uuid: {uuid!r}")

    helper.stdin.close()
    if helper.wait() != 0:
        fail("helper did not stop cleanly")
    emitter.stdin.close()
    if emitter.wait() != 0:
        fail("uinput emitter did not stop cleanly: " + emitter.stderr.read())
  '';
in
pkgs.testers.nixosTest {
  name = "wispr-flow-helper-keypress";
  nodes.machine = { pkgs, ... }: {
    boot.kernelModules = [ "uinput" ];
    programs.nix-ld = {
      enable = true;
      libraries = [ pkgs.stdenv.cc.cc ];
    };
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "${pkgs.python3}/bin/python3 ${witness} "
        "${runtimeInputs.helper} ${uinputEmitter}/bin/uinput-keypress-emitter"
    )
  '';
}
