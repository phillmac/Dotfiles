import unittest

from kubo_api_client import KuboClient


class KuboClientParsingTests(unittest.TestCase):
    def test_parse_add_splits_progress_entries_and_final_cid(self):
        events = [
            {"Name": "file.txt", "Bytes": 5},
            {"Name": "file.txt", "Hash": "bafyfile", "Size": "13"},
            {"Name": "dir", "Hash": "bafydir", "Size": "55"},
        ]

        result = KuboClient._parse_add(events)

        self.assertEqual(result.cid, "bafydir")
        self.assertEqual(result.progress[0].bytes, 5)
        self.assertEqual([entry.hash for entry in result.entries], ["bafyfile", "bafydir"])
        self.assertEqual(result.errors, [])


    def test_parse_add_does_not_invent_root_cid_for_unwrapped_batch(self):
        events = [
            {"Name": "one.txt", "Hash": "bafyone", "Size": "13"},
            {"Name": "two.txt", "Hash": "bafytwo", "Size": "21"},
        ]

        result = KuboClient._parse_add(events, has_root_cid=False)

        self.assertIsNone(result.cid)
        self.assertEqual([entry.hash for entry in result.entries], ["bafyone", "bafytwo"])

    def test_parse_pin_accepts_progress_with_or_without_bytes(self):
        events = [
            {"Progress": 2},
            {"Progress": 3, "Bytes": 1024},
            {"Pins": ["bafyroot"]},
        ]

        result = KuboClient._parse_pin(events)

        self.assertEqual(result.cid, "bafyroot")
        self.assertEqual(result.pins, ["bafyroot"])
        self.assertIsNone(result.progress[0].bytes)
        self.assertEqual(result.progress[1].bytes, 1024)

    def test_query_converts_pythonic_options_and_repeated_args(self):
        query = KuboClient._query(
            {"wrap_with_directory": True, "cid_version": 1, "ignored": None},
            args=["bafyone", "bafytwo"],
        )

        self.assertIn("arg=bafyone", query)
        self.assertIn("arg=bafytwo", query)
        self.assertIn("wrap-with-directory=true", query)
        self.assertIn("cid-version=1", query)
        self.assertNotIn("ignored", query)


if __name__ == "__main__":
    unittest.main()
