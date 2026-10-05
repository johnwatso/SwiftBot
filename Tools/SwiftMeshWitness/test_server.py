import concurrent.futures
import tempfile
import unittest
from pathlib import Path
from server import LeaseStore


class LeaseStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = str(Path(self.directory.name) / "leases.sqlite")
        self.now = 1000.0
        self.store = LeaseStore(self.path, clock=lambda: self.now)

    def tearDown(self):
        self.directory.cleanup()

    def test_only_one_concurrent_owner(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            statuses = list(pool.map(lambda node: self.store.apply("acquire", "bot", node, 0)[0], map(str, range(8))))
        self.assertEqual(statuses.count(200), 1)

    def test_expiry_fences_old_owner_and_terms_survive_restart(self):
        status, first = self.store.apply("acquire", "bot", "primary", 4)
        self.assertEqual(status, 200)
        self.now += 31
        restarted = LeaseStore(self.path, clock=lambda: self.now)
        self.assertEqual(restarted.apply("acquire", "bot", "standby", 0)[0], 503)
        self.now += 31
        status, second = restarted.apply("acquire", "bot", "standby", 0)
        self.assertEqual(status, 200)
        self.assertGreater(second["term"], first["term"])
        self.assertEqual(restarted.apply("renew", "bot", "primary", first["term"])[0], 409)
        self.assertEqual(restarted.apply("release", "bot", "primary", first["term"])[0], 409)

    def test_expired_renewal_cannot_revive_ownership(self):
        _, first = self.store.apply("acquire", "bot", "primary", 0)
        self.now += 30
        self.assertEqual(self.store.apply("renew", "bot", "primary", first["term"])[0], 409)

    def test_release_and_retry_do_not_lower_term(self):
        _, first = self.store.apply("acquire", "bot", "primary", 7)
        _, retry = self.store.apply("acquire", "bot", "primary", 7)
        self.assertEqual(first, retry)
        self.assertEqual(self.store.apply("release", "bot", "primary", first["term"])[0], 200)
        _, second = self.store.apply("acquire", "bot", "standby", 0)
        self.assertGreater(second["term"], first["term"])

    def test_restart_with_reset_monotonic_epoch_waits_out_old_lease(self):
        _, first = self.store.apply("acquire", "bot", "primary", 0)
        self.now = 0
        restarted = LeaseStore(self.path, clock=lambda: self.now)
        self.assertEqual(restarted.apply("acquire", "bot", "standby", 0)[0], 503)
        self.now = 31
        status, next_owner = restarted.apply("acquire", "bot", "standby", 0)
        self.assertEqual(status, 200)
        self.assertGreater(next_owner["term"], first["term"])

    def test_wall_clock_change_does_not_expire_monotonic_lease(self):
        from unittest.mock import patch
        self.store.apply("acquire", "bot", "primary", 0)
        with patch("server.time.time", return_value=10**12):
            self.assertEqual(self.store.apply("acquire", "bot", "standby", 0)[0], 409)

    def test_invalid_fields_are_rejected(self):
        self.assertEqual(self.store.apply("acquire", "bot", "primary", True)[0], 400)
        self.assertEqual(self.store.apply("acquire", "", "primary", 0)[0], 400)


if __name__ == "__main__":
    unittest.main()
