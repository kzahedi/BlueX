"""Single-instance lock so two collector processes never run concurrently.

Three production incidents so far: a manual backfill overlapping an agent's
dry-run, a manual restart racing a leftover run, and a scheduled incremental
run starting while a supervised backfill was still walking history. Each
double-run doubles the request rate against Telegram (the most damaging
consequence under this project's politeness/rate-limit discipline), plus
SQLite write-lock contention and duplicated work.

Deliberately NOT a PID file: a PID file left behind after a SIGKILL is
indistinguishable from a live holder without extra liveness checks (is that
PID still running? is it even the same process, given PID reuse?), and that
race is exactly the failure mode this module exists to avoid. `flock` ties
the lock to the OS file-descriptor table instead -- the kernel releases it
automatically when the holding process dies for ANY reason, including
SIGKILL, so a stale lock *file* on disk (contents or not) never blocks a
fresh acquisition.
"""
import contextlib
import fcntl
import os


class AlreadyRunningError(Exception):
    """Raised by single_instance() when another holder already has the lock."""


@contextlib.contextmanager
def single_instance(lock_path):
    """Hold an exclusive, non-blocking flock on `lock_path` for the `with` body.

    Opens its OWN file descriptor on every call -- required for the lock to
    mean anything: flock is scoped to the open-file-description, so re-using
    an already-held fd would make re-acquisition inside the same process a
    silent no-op instead of a real conflict check. A second, independent
    open() (this process or another) is what a genuinely racing collector
    process would do, and is what must fail here.

    Raises AlreadyRunningError immediately (never blocks) if the lock is
    already held. Always releases on the way out of the `with` block,
    including when the body raises.
    """
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise AlreadyRunningError(
                f"another process already holds the lock at {lock_path}"
            ) from e
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
