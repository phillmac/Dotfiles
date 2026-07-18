import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from kubo_api_client import KuboClient, _MultipartStream


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

    def test_multipart_paths_emits_directory_parts_for_empty_directories(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            (root / "with-file").mkdir(parents=True)
            (root / "with-file" / "file.txt").write_text("content", encoding="utf-8")
            (root / "empty" / "nested-empty").mkdir(parents=True)

            fields, opened = KuboClient._multipart_paths([root])

            try:
                parts = [(field, filename, content_type) for field, filename, _handle, content_type in fields]
                self.assertIn(("file", "root/with-file/file.txt", "text/plain"), parts)
                self.assertIn(("file", "root/empty", "application/x-directory"), parts)
                self.assertIn(("file", "root/empty/nested-empty", "application/x-directory"), parts)
            finally:
                for handle in opened:
                    handle.close()


    def test_multipart_paths_excludes_hidden_descendants_by_default(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            root.mkdir()
            (root / "visible.txt").write_text("public", encoding="utf-8")
            (root / ".env").write_text("SECRET=value", encoding="utf-8")
            (root / ".ssh").mkdir()
            (root / ".ssh" / "id_rsa").write_text("private key", encoding="utf-8")
            (root / "visible-dir").mkdir()
            (root / "visible-dir" / ".nested-secret").write_text("nested", encoding="utf-8")

            fields, opened = KuboClient._multipart_paths([root])

            try:
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type in fields]
                self.assertIn(("root/visible.txt", b"public", "text/plain"), parts)
                self.assertNotIn("root/.env", [filename for filename, _content, _content_type in parts])
                self.assertNotIn("root/.ssh/id_rsa", [filename for filename, _content, _content_type in parts])
                self.assertNotIn("root/visible-dir/.nested-secret", [filename for filename, _content, _content_type in parts])
                self.assertNotIn(b"SECRET=value", [content for _filename, content, _content_type in parts])
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_includes_hidden_descendants_when_requested(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            root.mkdir()
            (root / ".env").write_text("SECRET=value", encoding="utf-8")
            (root / ".ssh").mkdir()
            (root / ".ssh" / "id_rsa").write_text("private key", encoding="utf-8")

            fields, opened = KuboClient._multipart_paths([root], hidden=True)

            try:
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type in fields]
                self.assertIn(("root/.env", b"SECRET=value", "application/octet-stream"), parts)
                self.assertIn(("root/.ssh/id_rsa", b"private key", "application/octet-stream"), parts)
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_preserves_symlinks_without_dereferencing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            outside = Path(tmpdir) / "outside.txt"
            root.mkdir()
            outside.write_text("secret target bytes", encoding="utf-8")
            (root / "link.txt").symlink_to(outside)

            fields, opened = KuboClient._multipart_paths([root])

            try:
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type in fields]
                self.assertIn(("root/link.txt", bytes(outside), "application/symlink"), parts)
                self.assertNotIn(b"secret target bytes", [content for _filename, content, _content_type in parts])
                self.assertEqual(opened, [])
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_dereferences_symlinks_when_requested(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            outside = Path(tmpdir) / "outside.txt"
            root.mkdir()
            outside.write_text("target bytes", encoding="utf-8")
            (root / "link.txt").symlink_to(outside)

            fields, opened = KuboClient._multipart_paths([root], dereference_symlinks=True)

            try:
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type in fields]
                self.assertIn(("root/link.txt", b"target bytes", "text/plain"), parts)
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_recurses_into_symlinked_directories_when_dereferencing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            target = Path(tmpdir) / "target"
            root.mkdir()
            target.mkdir()
            (target / "nested.txt").write_text("nested target bytes", encoding="utf-8")
            (root / "linked-dir").symlink_to(target, target_is_directory=True)

            fields, opened = KuboClient._multipart_paths([root], dereference_symlinks=True)

            try:
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type in fields]
                self.assertIn(("root/linked-dir/nested.txt", b"nested target bytes", "text/plain"), parts)
                self.assertNotIn(("root/linked-dir", bytes(target), "application/symlink"), parts)
            finally:
                for handle in opened:
                    handle.close()

    def test_encode_multipart_streams_file_handles_incrementally(self):
        class ChunkedHandle:
            def __init__(self):
                self.read_sizes = []
                self.chunks = [b"alpha", b"beta", b""]

            def read(self, size=-1):
                self.read_sizes.append(size)
                return self.chunks.pop(0)

        handle = ChunkedHandle()

        body, content_type = KuboClient._encode_multipart([("file", "large.bin", handle, "application/octet-stream")])

        self.assertIsInstance(body, _MultipartStream)
        self.assertIn("multipart/form-data; boundary=", content_type)
        self.assertIn(b"alphabeta", b"".join(body))
        self.assertNotIn(-1, handle.read_sizes)
        self.assertEqual(handle.read_sizes, [_MultipartStream.chunk_size, _MultipartStream.chunk_size, _MultipartStream.chunk_size])


    def test_encode_multipart_percent_encodes_filename_parameter(self):
        body, _content_type = KuboClient._encode_multipart([
            ("file", "root/a+b%2Fquote\"name.txt", io.BytesIO(b"content"), "text/plain")
        ])

        header = next(part for part in body if part.startswith(b"Content-Disposition"))

        self.assertIn(b'filename="root/a%2Bb%252Fquote%22name.txt"', header)
        self.assertNotIn(b"a+b%2F", header)


    def test_post_stream_yields_events_before_reading_trailers(self):
        body = (
            b"1e\r\n"
            b'{"Name":"file.txt","Bytes":5}\n'
            b"\r\n"
            b"0\r\n"
            b"X-Stream-Error: delayed failure\r\n"
            b"\r\n"
        )
        trailer_offset = body.index(b"X-Stream-Error")

        class TrailerResponse:
            status = 200

            def __init__(self):
                self.fp = io.BytesIO(body)

            def __enter__(self):
                return self

            def __exit__(self, _exc_type, _exc, _tb):
                return False

            def getheader(self, name, default=None):
                if name == "Transfer-Encoding":
                    return "chunked"
                return default

        response = TrailerResponse()
        client = KuboClient("http://127.0.0.1:5001")

        with mock.patch.object(client, "_open_stream_response", return_value=response):
            events = client._post_stream("/api/v0/add", {}, None)
            first_event = next(events)
            position_after_first_event = response.fp.tell()
            remaining_events = list(events)

        self.assertEqual(first_event, {"Name": "file.txt", "Bytes": 5})
        self.assertLess(position_after_first_event, trailer_offset)
        self.assertEqual(remaining_events[0]["Message"], "delayed failure")

    def test_post_stream_surfaces_x_stream_error_trailer(self):
        class TrailerResponse:
            status = 200
            fp = io.BytesIO(
                b"1e\r\n"
                b'{"Name":"file.txt","Bytes":5}\n'
                b"\r\n"
                b"0\r\n"
                b"X-Stream-Error: mid-stream add failed\r\n"
                b"\r\n"
            )

            def __enter__(self):
                return self

            def __exit__(self, _exc_type, _exc, _tb):
                return False

            def getheader(self, name, default=None):
                if name == "Transfer-Encoding":
                    return "chunked"
                return default

        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "file.txt"
            path.write_text("content", encoding="utf-8")
            client = KuboClient("http://127.0.0.1:5001")

            with mock.patch.object(client, "_open_stream_response", return_value=TrailerResponse()):
                result = client.add(path)

        self.assertEqual(result.progress[0].bytes, 5)
        self.assertEqual(result.errors[0].message, "mid-stream add failed")
        self.assertEqual(result.errors[0].type, "stream")

    def test_parse_pin_preserves_progress_when_stream_trailer_reports_error(self):
        events = [
            {"Progress": 2},
            {"Message": "pin failed after progress", "Code": 200, "Type": "stream"},
        ]

        result = KuboClient._parse_pin(events)

        self.assertEqual(result.progress[0].progress, 2)
        self.assertEqual(result.errors[0].message, "pin failed after progress")

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
