// spawn-helper — make a pty the controlling terminal, then exec the real command.
//
// Why this exists: the app can't use forkpty()/fork() to launch PTY children,
// because running any managed code (or non-async-signal-safe libc such as
// setenv/malloc) on the child side of a fork in this multi-threaded CLR + AppKit
// process corrupts the child and crashes it (SIGBUS). So UnixPtyProcess uses
// posix_spawn instead. But on macOS, posix_spawn's POSIX_SPAWN_SETSID makes the
// child a session leader WITHOUT giving it a controlling terminal (the pty is
// opened before setsid, so open-acquires-ctty doesn't apply). Without a
// controlling terminal, /dev/tty can't be opened and ssh's host-key confirmation
// ("read_passphrase: can't open /dev/tty") fails with "Host key verification
// failed". This tiny helper is posix_spawn'd instead of the real program, with
// POSIX_SPAWN_SETSID set and the pty slave already on fd 0/1/2; it issues the one
// call posix_spawn can't (TIOCSCTTY) to claim that pty as its controlling
// terminal, then execs the real program in its place.
//
//   spawn-helper <program> [args...]
//
// Uses only async-signal-safe calls and performs no allocations.
#include <sys/ioctl.h>
#include <unistd.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        static const char msg[] = "spawn-helper: missing command\n";
        (void)write(2, msg, sizeof msg - 1);
        return 2;
    }
    // Claim our stdin pty as the controlling terminal. Harmless where it's already
    // set (e.g. Linux, where open-acquires-ctty already ran), so it's unconditional.
    ioctl(STDIN_FILENO, TIOCSCTTY, 0);
    execvp(argv[1], &argv[1]);
    perror("spawn-helper: exec");
    return 127;
}
