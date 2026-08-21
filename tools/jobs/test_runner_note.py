"""Make `unittest discover -s tools/jobs` say something instead of nothing.

`tools/jobs/test_jobs.py` is written in pytest style (fixtures, parametrize),
so unittest's discovery finds zero tests in this directory and exits cleanly
with "NO TESTS RAN" — indistinguishable, at a glance, from "everything
passed". This project has already been burned by tests that could not fail;
a silent zero-test run is the same class of problem.

This module contributes one unittest-visible test that always skips with an
explanatory reason, so a unittest run reports `OK (skipped=1)` with the
correct command in the output rather than an empty, reassuring silence.
"""
import unittest


class JobsSuiteRunnerNote(unittest.TestCase):
    def test_jobs_suite_requires_pytest(self):
        raise unittest.SkipTest(
            "tools/jobs tests are pytest-style and were NOT run by unittest. "
            "Run: python3 -m pytest tools/jobs/test_jobs.py")
