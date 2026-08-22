import os
import tempfile
import unittest

from tools.social.telegram.single_instance import (AlreadyRunningError,
                                                    single_instance)


class TestSingleInstance(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.lock_path = os.path.join(self._tmpdir.name, "test.db.collector.lock")

    def tearDown(self):
        self._tmpdir.cleanup()

    def test_second_acquisition_in_same_process_raises(self):
        # A bare flock on the SAME fd is re-entrant within one process, so
        # this only proves anything if the second acquisition goes through
        # its own, independent open() -- exactly what a second OS process
        # racing the same lock file would do.
        with single_instance(self.lock_path):
            with self.assertRaises(AlreadyRunningError):
                with single_instance(self.lock_path):
                    pass  # pragma: no cover -- must not be reached

    def test_lock_is_released_after_context_exits(self):
        with single_instance(self.lock_path):
            pass
        # Should succeed cleanly now that the first holder has released it.
        with single_instance(self.lock_path):
            pass

    def test_lock_is_released_when_body_raises(self):
        with self.assertRaises(ValueError):
            with single_instance(self.lock_path):
                raise ValueError("boom")
        # The exception must not leave the lock held.
        with single_instance(self.lock_path):
            pass

    def test_stale_lock_file_on_disk_does_not_block_acquisition(self):
        # A lock file can be left on disk (e.g. after a SIGKILL) with nobody
        # actually holding the flock -- that must NOT be mistaken for "in
        # use". This is exactly the failure mode a bare PID file has and
        # flock avoids.
        with open(self.lock_path, "w") as f:
            f.write(str(os.getpid()))
        with single_instance(self.lock_path):
            pass


if __name__ == "__main__":
    unittest.main()
