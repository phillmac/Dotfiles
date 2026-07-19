import io
import os
import subprocess
import signal
import sys
import time
from pathlib import Path, PureWindowsPath
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


    def test_parse_add_suppresses_cid_when_stream_reports_error(self):
        events = [
            {"Name": "root/child.txt", "Hash": "bafychild", "Size": "13"},
            {"Message": "add failed before root", "Code": 200, "Type": "stream"},
        ]

        result = KuboClient._parse_add(events)

        self.assertIsNone(result.cid)
        self.assertEqual([entry.hash for entry in result.entries], ["bafychild"])
        self.assertEqual(result.errors[0].message, "add failed before root")


    def test_multipart_paths_rejects_directories_when_recursive_is_false(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            root.mkdir()
            (root / "file.txt").write_text("content", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "recursive=True"):
                KuboClient._multipart_paths([root], recursive=False)

    def test_add_does_not_open_directory_files_when_recursive_is_unset(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            root.mkdir()
            file_path = root / "file.txt"
            file_path.write_text("content", encoding="utf-8")
            client = KuboClient("http://127.0.0.1:5001")

            with mock.patch.object(Path, "open", wraps=Path.open) as open_mock:
                with self.assertRaisesRegex(ValueError, "recursive=True"):
                    client.add(root)

            open_mock.assert_not_called()

    def test_multipart_relative_name_uses_posix_separators_for_windows_paths(self):
        root = PureWindowsPath(r"C:\uploads\root")
        child = PureWindowsPath(r"C:\uploads\root\sub\file.txt")

        self.assertEqual(
            KuboClient._multipart_relative_name(root, child),
            "root/sub/file.txt",
        )


    def test_multipart_paths_emits_directory_parts_for_empty_directories(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            (root / "with-file").mkdir(parents=True)
            (root / "with-file" / "file.txt").write_text("content", encoding="utf-8")
            (root / "empty" / "nested-empty").mkdir(parents=True)

            fields, opened = KuboClient._multipart_paths([root])

            try:
                parts = [(field, filename, content_type) for field, filename, _handle, content_type, _abspath, _headers in fields]
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
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type, _abspath, _headers in fields]
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
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type, _abspath, _headers in fields]
                self.assertIn(("root/.env", b"SECRET=value", "application/octet-stream"), parts)
                self.assertIn(("root/.ssh/id_rsa", b"private key", "application/octet-stream"), parts)
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_emits_abspath_header_for_nocopy_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            root.mkdir()
            file_path = root / "file.txt"
            file_path.write_text("content", encoding="utf-8")

            fields, opened = KuboClient._multipart_paths([root], nocopy=True)

            try:
                self.assertEqual(len(fields), 1)
                field, filename, handle, content_type, abspath, headers = fields[0]
                self.assertEqual((field, filename, content_type), ("file", "root/file.txt", "text/plain"))
                self.assertEqual(abspath, str(file_path.absolute()))

                body, _content_type = KuboClient._encode_multipart(fields)
                part = b"".join(body)

                self.assertIn(f"Abspath: {file_path.absolute()}\r\n".encode(), part)
                self.assertIn(b"content", part)
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_embeds_preserved_mode_and_mtime_in_part_name(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = Path(tmpdir) / "script.sh"
            file_path.write_text("#!/bin/sh\n", encoding="utf-8")
            file_path.chmod(0o754)
            os.utime(
                file_path,
                ns=(1_700_000_000_123_456_789, 1_700_000_001_987_654_321),
            )

            fields, opened = KuboClient._multipart_paths(
                [file_path], preserve_mode=True, preserve_mtime=True
            )

            try:
                field, filename, handle, content_type, abspath, headers = fields[0]
                self.assertEqual(filename, "script.sh")
                self.assertEqual(content_type, "text/x-sh")
                self.assertIsNone(abspath)
                self.assertEqual(handle.read(), b"#!/bin/sh\n")
                self.assertEqual(field, "file?mode=754&mtime=1700000001&mtime-nsecs=987654321")
                self.assertEqual(headers, {})

                body, _content_type = KuboClient._encode_multipart(fields)
                header = next(
                    part for part in body if part.startswith(b"Content-Disposition")
                )
                self.assertIn(b'name="file?mode=754&mtime=1700000001&mtime-nsecs=987654321"', header)

                part = b"".join(body)
                self.assertNotIn(b"mode: 754\r\n", part)
                self.assertNotIn(b"mtime: 1700000001\r\n", part)
                self.assertNotIn(b"mtime-nsecs: 987654321\r\n", part)
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_embeds_directory_metadata_when_preserved(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            empty = root / "empty"
            empty.mkdir(parents=True)
            empty.chmod(0o750)
            os.utime(
                empty,
                ns=(1_700_000_010_000_000_000, 1_700_000_011_222_333_444),
            )

            fields, opened = KuboClient._multipart_paths(
                [root], preserve_mode=True, preserve_mtime=True
            )

            try:
                directory_field, directory_headers = next(
                    (field, headers)
                    for field, filename, _handle, content_type, _abspath, headers in fields
                    if filename == "root/empty" and content_type == "application/x-directory"
                )
                self.assertEqual(directory_field, "file?mode=750&mtime=1700000011&mtime-nsecs=222333444")
                self.assertEqual(directory_headers, {})
            finally:
                for handle in opened:
                    handle.close()


    def test_multipart_paths_embeds_metadata_for_non_empty_directories(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            subdir = root / "subdir"
            subdir.mkdir(parents=True)
            (subdir / "file.txt").write_text("content", encoding="utf-8")
            root.chmod(0o751)
            subdir.chmod(0o750)
            os.utime(root, ns=(1_700_000_020_000_000_000, 1_700_000_021_111_222_333))
            os.utime(subdir, ns=(1_700_000_030_000_000_000, 1_700_000_031_444_555_666))

            fields, opened = KuboClient._multipart_paths(
                [root], preserve_mode=True, preserve_mtime=True
            )

            try:
                directory_parts = {
                    filename: field
                    for field, filename, _handle, content_type, _abspath, _headers in fields
                    if content_type == "application/x-directory"
                }
                self.assertIn("root", directory_parts)
                self.assertIn("root/subdir", directory_parts)
                self.assertEqual(directory_parts["root"], "file?mode=751&mtime=1700000021&mtime-nsecs=111222333")
                self.assertEqual(directory_parts["root/subdir"], "file?mode=750&mtime=1700000031&mtime-nsecs=444555666")
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_emits_preserved_directories_before_descendants(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            subdir = root / "subdir"
            subdir.mkdir(parents=True)
            (subdir / "file.txt").write_text("content", encoding="utf-8")

            fields, opened = KuboClient._multipart_paths(
                [root], preserve_mode=True, preserve_mtime=True
            )

            try:
                filenames = [filename for _field, filename, _handle, _content_type, _abspath, _headers in fields]
                self.assertLess(filenames.index("root"), filenames.index("root/subdir"))
                self.assertLess(filenames.index("root/subdir"), filenames.index("root/subdir/file.txt"))
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
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type, _abspath, _headers in fields]
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
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type, _abspath, _headers in fields]
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
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type, _abspath, _headers in fields]
                self.assertIn(("root/linked-dir/nested.txt", b"nested target bytes", "text/plain"), parts)
                self.assertNotIn(("root/linked-dir", bytes(target), "application/symlink"), parts)
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_prunes_symlink_directory_cycles_when_dereferencing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            child = root / "child"
            child.mkdir(parents=True)
            (child / "file.txt").write_text("nested target bytes", encoding="utf-8")
            (child / "loop").symlink_to(root, target_is_directory=True)

            fields, opened = KuboClient._multipart_paths([root], dereference_symlinks=True)

            try:
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type, _abspath, _headers in fields]
                self.assertIn(("root/child/file.txt", b"nested target bytes", "text/plain"), parts)
                self.assertNotIn("root/child/loop/child/file.txt", [filename for filename, _content, _content_type in parts])
            finally:
                for handle in opened:
                    handle.close()

    def test_multipart_paths_keeps_duplicate_symlinked_directory_targets_when_dereferencing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            target = root / "a"
            target.mkdir(parents=True)
            (target / "file.txt").write_text("target bytes", encoding="utf-8")
            (root / "b").symlink_to(target, target_is_directory=True)

            fields, opened = KuboClient._multipart_paths([root], dereference_symlinks=True)

            try:
                parts = [(filename, handle.read(), content_type) for _field, filename, handle, content_type, _abspath, _headers in fields]
                self.assertIn(("root/a/file.txt", b"target bytes", "text/plain"), parts)
                self.assertIn(("root/b/file.txt", b"target bytes", "text/plain"), parts)
                self.assertNotIn(("root/b", bytes(target), "application/symlink"), parts)
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

        body, content_type = KuboClient._encode_multipart([("file", "large.bin", handle, "application/octet-stream", None, {})])

        self.assertIsInstance(body, _MultipartStream)
        self.assertIn("multipart/form-data; boundary=", content_type)
        joined = b"".join(body)
        self.assertIn(b"alphabeta", joined)
        self.assertNotIn(-1, handle.read_sizes)
        self.assertEqual(handle.read_sizes, [_MultipartStream.chunk_size, _MultipartStream.chunk_size, _MultipartStream.chunk_size])

    def test_recursive_multipart_paths_defer_file_opening_until_streamed(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "root"
            root.mkdir()
            first = root / "first.txt"
            second = root / "second.txt"
            first.write_text("alpha", encoding="utf-8")
            second.write_text("beta", encoding="utf-8")
            open_counts = {first: 0, second: 0}
            close_counts = {first: 0, second: 0}
            real_open = Path.open

            class TrackingHandle:
                def __init__(self, path, handle):
                    self.path = path
                    self.handle = handle

                def read(self, size=-1):
                    return self.handle.read(size)

                def close(self):
                    close_counts[self.path] += 1
                    return self.handle.close()

                def __enter__(self):
                    return self

                def __exit__(self, exc_type, exc, tb):
                    self.close()
                    return False

            def tracking_open(path, *args, **kwargs):
                path = Path(path)
                if path in open_counts:
                    open_counts[path] += 1
                    return TrackingHandle(path, real_open(path, *args, **kwargs))
                return real_open(path, *args, **kwargs)

            with mock.patch.object(Path, "open", tracking_open):
                fields, opened = KuboClient._multipart_paths([root])
                self.assertEqual(open_counts, {first: 0, second: 0})
                self.assertEqual(opened, [])

                body, _content_type = KuboClient._encode_multipart(fields)
                joined = b"".join(body)
                self.assertIn(b"alpha", joined)
                self.assertIn(b"beta", joined)

            self.assertEqual(open_counts, {first: 1, second: 1})
            self.assertEqual(close_counts, {first: 1, second: 1})


    def test_encode_multipart_percent_encodes_filename_parameter(self):
        body, _content_type = KuboClient._encode_multipart([
            ("file", "root/a+b%2Fquote\"name.txt", io.BytesIO(b"content"), "text/plain", None, {})
        ])

        header = next(
            part for part in body if part.startswith(b"Content-Disposition")
        )

        self.assertIn(b'filename="root%2Fa%2Bb%252Fquote%22name.txt"', header)
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

    def test_post_stream_closes_underlying_connection_after_success(self):
        class TrailerResponse:
            status = 200

            def __init__(self):
                self.fp = io.BytesIO(b'{"Name":"file.txt","Bytes":5}\n')
                self._kubo_connection = mock.Mock()

            def __enter__(self):
                return self

            def __exit__(self, _exc_type, _exc, _tb):
                return False

            def getheader(self, name, default=None):
                return default

            def readline(self):
                return self.fp.readline()

        response = TrailerResponse()
        client = KuboClient("http://127.0.0.1:5001")

        with mock.patch.object(client, "_open_stream_response", return_value=response):
            events = list(client._post_stream("/api/v0/add", {}, None))

        self.assertEqual(events, [{"Name": "file.txt", "Bytes": 5}])
        response._kubo_connection.close.assert_called_once_with()

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


    def test_parse_add_preserves_partial_events_when_transport_fails(self):
        def events():
            yield {"Name": "file.txt", "Bytes": 5}
            yield {"Name": "file.txt", "Hash": "bafyfile", "Size": "13"}
            from kubo_api_client import KuboError, KuboErrorException
            raise KuboErrorException(KuboError("socket timed out"))

        result = KuboClient._parse_add(events())

        self.assertEqual(result.progress[0].bytes, 5)
        self.assertEqual([entry.hash for entry in result.entries], ["bafyfile"])
        self.assertIsNone(result.cid)
        self.assertEqual(result.errors[0].message, "socket timed out")
        self.assertEqual(len(result.raw_events), 2)

    def test_parse_pin_preserves_progress_when_stream_trailer_reports_error(self):
        events = [
            {"Progress": 2},
            {"Message": "pin failed after progress", "Code": 200, "Type": "stream"},
        ]

        result = KuboClient._parse_pin(events)

        self.assertEqual(result.progress[0].progress, 2)
        self.assertEqual(result.errors[0].message, "pin failed after progress")


    def test_parse_pin_preserves_partial_events_when_transport_fails(self):
        def events():
            yield {"Progress": 2, "Bytes": 1024}
            from kubo_api_client import KuboError, KuboErrorException
            raise KuboErrorException(KuboError("connection reset"))

        result = KuboClient._parse_pin(events())

        self.assertEqual(result.progress[0].progress, 2)
        self.assertEqual(result.progress[0].bytes, 1024)
        self.assertEqual(result.errors[0].message, "connection reset")
        self.assertEqual(len(result.raw_events), 1)

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


    def test_normalize_api_honors_https_multiaddr_protocol(self):
        self.assertEqual(
            KuboClient._normalize_api("/ip4/203.0.113.5/tcp/443/https"),
            "https://203.0.113.5:443",
        )
        self.assertEqual(
            KuboClient._normalize_api("/dns/kubo.example.com/tcp/443/https"),
            "https://kubo.example.com:443",
        )

    def test_normalize_api_keeps_http_multiaddrs_as_http(self):
        self.assertEqual(
            KuboClient._normalize_api("/ip4/127.0.0.1/tcp/5001"),
            "http://127.0.0.1:5001",
        )
        self.assertEqual(
            KuboClient._normalize_api("/dns4/localhost/tcp/5001/http"),
            "http://localhost:5001",
        )

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


class PinWithExportRetryTests(unittest.TestCase):
    def test_missing_block_cid_from_error_extracts_kubo_offline_error(self):
        from kubo_api_client import KuboError
        from pin_with_export_retry import missing_block_cid_from_error

        error = KuboError(
            "pin: block was not found locally (offline): ipld: could not find QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kxyz"
        )

        self.assertEqual(
            missing_block_cid_from_error(error),
            "QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kxyz",
        )

    def test_missing_block_cid_from_error_stops_qm_cid_at_quote(self):
        from kubo_api_client import KuboError
        from pin_with_export_retry import missing_block_cid_from_error

        error = KuboError(
            'pin: block was not found locally (offline): ipld: could not find "QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kxyz"'
        )

        self.assertEqual(
            missing_block_cid_from_error(error),
            "QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kxyz",
        )

    def test_missing_block_cid_from_error_extracts_cidv1(self):
        from kubo_api_client import KuboError
        from pin_with_export_retry import missing_block_cid_from_error

        error = KuboError("block was not found locally: ipld: could not find bafybeigdyrztq")
        self.assertEqual(missing_block_cid_from_error(error), "bafybeigdyrztq")

    def test_pin_with_export_retry_invokes_exporter_once_then_retries(self):
        from kubo_api_client import KuboError, PinResult
        import pin_with_export_retry

        calls = []
        results = [
            PinResult([], [], None, [KuboError("ipld: could not find QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kabc")], []),
            PinResult([], ["QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1root"], "QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1root", [], []),
        ]
        client = mock.Mock()
        client.pin_add.side_effect = lambda *a, **k: (calls.append("pin"), results.pop(0))[1]

        def fake_export(missing_cid, export_command, *, timeout=None):
            calls.append(("export", missing_cid, str(export_command), timeout))

        with mock.patch.object(pin_with_export_retry, "KuboClient", return_value=client), \
             mock.patch.object(pin_with_export_retry, "export_missing_cid", side_effect=fake_export):
            result = pin_with_export_retry.pin_with_export_retry(
                "QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1root",
                api="http://127.0.0.1:5001",
                timeout=10,
                export_command="/tmp/exporter",
                export_timeout=None,
            )

        self.assertEqual(result.errors, [])
        self.assertEqual(calls, ["pin", ("export", "QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kabc", "/tmp/exporter", None), "pin"])

    def test_exporter_receives_missing_cid_as_separate_argument(self):
        import pin_with_export_retry

        with mock.patch.object(pin_with_export_retry.subprocess, "Popen") as popen:
            process = popen.return_value
            process.wait.return_value = 0
            pin_with_export_retry.export_missing_cid("QmCID;touch injected", "/tmp/exporter")

        popen.assert_called_once()
        self.assertEqual(popen.call_args.args[0], ["/tmp/exporter", "QmCID;touch injected"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_nonzero_exporter_status_returns_useful_error(self):
        from kubo_api_client import KuboError, PinResult
        import pin_with_export_retry

        client = mock.Mock()
        client.pin_add.return_value = PinResult([], [], None, [KuboError("ipld: could not find QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kabc")], [])
        failure = pin_with_export_retry.ExportFailure("QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kabc", "/tmp/exporter", "exit status 23", "The synchronous export/import command returned failure.")

        with mock.patch.object(pin_with_export_retry, "KuboClient", return_value=client), \
             mock.patch.object(pin_with_export_retry, "export_missing_cid", side_effect=pin_with_export_retry.ExportFailed(failure)):
            result = pin_with_export_retry.pin_with_export_retry("Qmroot", export_command="/tmp/exporter")

        self.assertEqual(client.pin_add.call_count, 1)
        self.assertIn("QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kabc", result.errors[-1].message)
        self.assertIn("exit status 23", result.errors[-1].message)

    def test_exporter_timeout_is_reported(self):
        import pin_with_export_retry

        with mock.patch.object(pin_with_export_retry.subprocess, "Popen") as popen, \
             mock.patch.object(pin_with_export_retry, "_terminate_process_group") as kill_group:
            process = popen.return_value
            process.wait.side_effect = subprocess.TimeoutExpired(["/tmp/exporter"], 1)
            process.pid = 12345
            process.poll.return_value = None
            with self.assertRaises(pin_with_export_retry.ExportFailed) as cm:
                pin_with_export_retry.export_missing_cid("Qmabc", "/tmp/exporter", timeout=1)

        kill_group.assert_called_once_with(process, signal.SIGTERM)
        self.assertIn("timeout after 1 seconds", cm.exception.failure.status)


    def test_default_exporter_path_is_under_bashrc_tree(self):
        import pin_with_export_retry

        self.assertEqual(
            Path(pin_with_export_retry.DEFAULT_EXPORT_COMMAND),
            Path("pin_with_export_retry.py").resolve().parent / ".bashrc.d" / "carpo.bashrc.d" / "rhea-wasabi-pebble-export-laptop-dag-sync",
        )
        self.assertTrue(Path(pin_with_export_retry.DEFAULT_EXPORT_COMMAND).is_file())

    def test_exporter_launch_file_not_found_is_structured(self):
        import pin_with_export_retry

        with mock.patch.object(pin_with_export_retry.subprocess, "Popen", side_effect=FileNotFoundError(2, "No such file or directory")):
            with self.assertRaises(pin_with_export_retry.ExportFailed) as cm:
                pin_with_export_retry.export_missing_cid("Qmabc", "/missing/exporter")
        self.assertIn("could not start exporter", cm.exception.failure.status)
        self.assertIn("No synchronous export/import was performed", cm.exception.failure.message)

    def test_exporter_launch_permission_error_is_structured(self):
        import pin_with_export_retry

        with mock.patch.object(pin_with_export_retry.subprocess, "Popen", side_effect=PermissionError(13, "Permission denied")):
            with self.assertRaises(pin_with_export_retry.ExportFailed) as cm:
                pin_with_export_retry.export_missing_cid("Qmabc", "/tmp/exporter")
        self.assertIn("Permission denied", cm.exception.failure.status)

    def test_pin_is_not_retried_after_launch_failure(self):
        from kubo_api_client import KuboError, PinResult
        import pin_with_export_retry

        client = mock.Mock()
        client.pin_add.return_value = PinResult([], [], None, [KuboError("ipld: could not find Qmabc")], [])
        with mock.patch.object(pin_with_export_retry, "KuboClient", return_value=client), \
             mock.patch.object(pin_with_export_retry.subprocess, "Popen", side_effect=FileNotFoundError(2, "No such file or directory")):
            result = pin_with_export_retry.pin_with_export_retry("Qmroot", export_command="/missing/exporter")
        self.assertEqual(client.pin_add.call_count, 1)
        self.assertIn("could not start exporter", result.errors[-1].message)

    def test_signal_handlers_restored_after_success(self):
        import pin_with_export_retry

        old_int = signal.getsignal(signal.SIGINT)
        old_term = signal.getsignal(signal.SIGTERM)
        with mock.patch.object(pin_with_export_retry.subprocess, "Popen") as popen:
            popen.return_value.wait.return_value = 0
            pin_with_export_retry.export_missing_cid("Qmabc", "/tmp/exporter")
        self.assertIs(signal.getsignal(signal.SIGINT), old_int)
        self.assertIs(signal.getsignal(signal.SIGTERM), old_term)

    def test_sigkill_escalation_when_cleanup_times_out(self):
        import pin_with_export_retry

        process = mock.Mock()
        process.pid = 123
        process.wait.side_effect = [subprocess.TimeoutExpired(["cmd"], 5), 0]
        with mock.patch.object(pin_with_export_retry.os, "killpg") as killpg:
            pin_with_export_retry._terminate_process_group(process, signal.SIGTERM, wait_timeout=0.01)
        self.assertEqual(killpg.call_args_list[0].args, (123, signal.SIGTERM))
        self.assertEqual(killpg.call_args_list[1].args, (123, signal.SIGKILL))

    def test_no_fifo_or_socket_write_occurs_in_python_workflow(self):
        from kubo_api_client import KuboError, PinResult
        import pin_with_export_retry

        client = mock.Mock()
        client.pin_add.side_effect = [
            PinResult([], [], None, [KuboError("ipld: could not find QmYwAPJzv5CZsnAzt8auVZRn2jWv2ztBzXgVdqMPM1kabc")], []),
            PinResult([], ["Qmroot"], "Qmroot", [], []),
        ]
        with mock.patch.object(pin_with_export_retry, "KuboClient", return_value=client), \
             mock.patch.object(pin_with_export_retry, "export_missing_cid"), \
             mock.patch("os.open") as os_open, \
             mock.patch("socket.socket") as socket_mock, \
             mock.patch("time.sleep") as sleep_mock:
            pin_with_export_retry.pin_with_export_retry("Qmroot")

        os_open.assert_not_called()
        socket_mock.assert_not_called()
        sleep_mock.assert_not_called()

    def test_fifo_consumer_uses_same_sync_exporter(self):
        text = Path(".bashrc.d/carpo.bashrc.d/ipfs.bashrc").read_text(encoding="utf-8")
        self.assertIn('local queue="rhea.wasabi.pebble.export.laptop.dag.queue"', text)
        self.assertIn('"$exporter" "$cid"', text)


    def test_fifo_consumer_retries_current_cid_before_next(self):
        text = Path(".bashrc.d/carpo.bashrc.d/ipfs.bashrc").read_text(encoding="utf-8")
        self.assertIn('while (( shutting_down == 0 ))', text)
        self.assertIn('"$exporter" "$cid"', text)
        self.assertIn('status=$?', text)
        self.assertIn('Exporter failed for ${cid} with status ${status}', text)
        self.assertLess(text.index('while (( shutting_down == 0 ))'), text.index('done < "$queue"'))

    def test_fifo_consumer_resolves_default_exporter_without_path_and_override_remains(self):
        text = Path(".bashrc.d/carpo.bashrc.d/ipfs.bashrc").read_text(encoding="utf-8")
        self.assertIn('dirname -- "${BASH_SOURCE[0]}"', text)
        self.assertIn('RHEA_WASABI_PEBBLE_EXPORT_LAPTOP_DAG_SYNC:-${script_dir}/rhea-wasabi-pebble-export-laptop-dag-sync', text)
        self.assertIn('[[ ! -x "$exporter" ]]', text)


    def test_successful_export_does_not_call_process_group_cleanup(self):
        import pin_with_export_retry

        with mock.patch.object(pin_with_export_retry.subprocess, "Popen") as popen, \
             mock.patch.object(pin_with_export_retry, "_terminate_process_group") as cleanup:
            popen.return_value.wait.return_value = 0
            pin_with_export_retry.export_missing_cid("Qmabc", "/tmp/exporter")
        cleanup.assert_not_called()

    def test_real_sigint_and_sigterm_delivery_cleanup_process_group(self):
        import pin_with_export_retry

        script = Path(pin_with_export_retry.DEFAULT_EXPORT_COMMAND)
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            hook = tmp / "hook.py"
            child_pid = tmp / "child.pid"
            hook.write_text(
                "#!/usr/bin/env python3\n"
                "import os, signal, subprocess, sys, time\n"
                "child = subprocess.Popen([sys.executable, '-c', \"import time; time.sleep(60)\"])\n"
                f"open({str(child_pid)!r}, 'w').write(str(child.pid))\n"
                "open(sys.argv[1], 'w').write(str(os.getpid()))\n"
                "time.sleep(60)\n",
                encoding="utf-8",
            )
            hook.chmod(0o755)
            driver = tmp / "driver.py"
            driver.write_text(
                "import os, signal, sys, time\n"
                f"sys.path.insert(0, {str(Path.cwd())!r})\n"
                "import pin_with_export_retry\n"
                "try:\n"
                f"    pin_with_export_retry.export_missing_cid('Qmabc', {str(script)!r})\n"
                "except KeyboardInterrupt:\n"
                "    raise SystemExit(130)\n"
                "except SystemExit as exc:\n"
                "    raise\n"
                "raise SystemExit(0)\n",
                encoding="utf-8",
            )
            env = {**os.environ, "IPFS_DAG_EXPORT_SYNC_HOOK": str(hook), "IPFS_DAG_EXPORT_LOCK": str(tmp / "lock")}
            for sig, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
                marker = tmp / f"marker-{sig.value}"
                env["IPFS_DAG_EXPORT_SYNC_HOOK"] = str(hook)
                # wrapper passes the marker as CID-independent argv[1] via hook script's CID argument path requirement is not useful here;
                # use a tiny shell hook to write marker and spawn a child instead.
                shell_hook = tmp / f"hook-{sig.value}.sh"
                code = (
                    "import os,subprocess,sys,time; "
                    "p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                    f"open({str(child_pid)!r}, 'w').write(str(p.pid)); "
                    f"open({str(marker)!r}, 'w').write(str(os.getpid())); "
                    "time.sleep(60)"
                )
                shell_hook.write_text(
                    "#!/usr/bin/env bash\n"
                    f"python3 -c {code!r}\n",
                    encoding="utf-8",
                )
                shell_hook.chmod(0o755)
                env["IPFS_DAG_EXPORT_SYNC_HOOK"] = str(shell_hook)
                proc = subprocess.Popen([sys.executable, str(driver)], env=env)
                deadline = time.time() + 5
                while time.time() < deadline and not marker.exists():
                    time.sleep(0.05)
                self.assertTrue(marker.exists())
                proc.send_signal(sig)
                self.assertEqual(proc.wait(timeout=5), expected)
                if child_pid.exists():
                    pid = int(child_pid.read_text())
                    for _ in range(20):
                        ps = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True)
                        if ps.returncode != 0 or "Z" in ps.stdout:
                            break
                        time.sleep(0.05)
                    ps = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True)
                    self.assertTrue(ps.returncode != 0 or "Z" in ps.stdout)

    def test_fifo_worker_traps_are_scoped_to_subshell(self):
        script = Path(".bashrc.d/carpo.bashrc.d/ipfs.bashrc").resolve()
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            probe = tmp / "probe.sh"
            probe.write_text(
                "#!/usr/bin/env bash\n"
                "cd \"$1\" || exit 1\n"
                "source \"$2\"\n"
                "trap 'echo parent-int' INT\n"
                "trap 'echo parent-term' TERM\n"
                "before_int=$(trap -p INT)\n"
                "before_term=$(trap -p TERM)\n"
                "RHEA_WASABI_PEBBLE_EXPORT_LAPTOP_DAG_SYNC=/missing rhea.wasabi.pebble.export.laptop.dag >/dev/null 2>&1 || true\n"
                "after_int=$(trap -p INT)\n"
                "after_term=$(trap -p TERM)\n"
                "[[ $before_int == $after_int && $before_term == $after_term ]] || exit 2\n"
                "declare -p shutting_down >/dev/null 2>&1 && exit 3\n"
                "exit 0\n",
                encoding="utf-8",
            )
            probe.chmod(0o755)
            subprocess.run([str(probe), str(tmp), str(script)], check=True, timeout=5)

    def test_direct_and_fifo_paths_use_same_lock_and_flock_serializes(self):
        script = Path(".bashrc.d/carpo.bashrc.d/rhea-wasabi-pebble-export-laptop-dag-sync").resolve()
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            hook = tmp / "hook.sh"
            hook.write_text("#!/usr/bin/env bash\nprintf 'start %s %s\\n' \"$1\" \"$(date +%s%N)\" >> \"$LOG\"\nsleep 0.2\nprintf 'end %s %s\\n' \"$1\" \"$(date +%s%N)\" >> \"$LOG\"\n", encoding="utf-8")
            hook.chmod(0o755)
            env = {**os.environ, "IPFS_DAG_EXPORT_SYNC_HOOK": str(hook), "IPFS_DAG_EXPORT_LOCK": str(tmp / "shared.lock"), "LOG": str(tmp / "log")}
            p1 = subprocess.Popen([str(script), "cid-one"], env=env)
            p2 = subprocess.Popen([str(script), "cid-two"], env=env)
            self.assertEqual(p1.wait(timeout=5), 0)
            self.assertEqual(p2.wait(timeout=5), 0)
            events = (tmp / "log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(len(events), 4)
        self.assertEqual(events[0].split()[0], "start")
        self.assertEqual(events[1].split()[0], "end")
        self.assertEqual(events[2].split()[0], "start")
        self.assertEqual(events[3].split()[0], "end")


if __name__ == "__main__":
    unittest.main()
