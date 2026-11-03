from contextlib import redirect_stderr, redirect_stdout
from email.utils import formatdate
from http.client import IncompleteRead
import importlib.util
import io
from pathlib import Path
import ssl
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
from urllib.request import Request


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("http_fetch", ROOT / "scripts/http_fetch.py")
http = importlib.util.module_from_spec(spec)
spec.loader.exec_module(http)
URL = "https://releases.unraid.net/json?includePublic=1"


class Response(io.BytesIO):
    def __init__(self, data=b"[]", url=URL):
        super().__init__(data)
        self.url = url
        self.status = 200


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.sleep = Mock()
        self.addCleanup(patch.stopall)
        patch.object(http.time, "sleep", self.sleep).start()
        patch.object(http.time, "time", return_value=1000).start()
        self.stderr = io.StringIO()
        self.stdout = io.StringIO()
        self.enterContext(redirect_stderr(self.stderr))
        self.enterContext(redirect_stdout(self.stdout))

    def error(self, code, headers=None):
        error = HTTPError(URL, code, "upstream rejected request", headers or {},
                          io.BytesIO(b"must not log untrusted error body"))
        self.addCleanup(error.close)
        return error

    def fetch(self, replies, **kwargs):
        self.opener = Mock(side_effect=replies)
        return http.get_bytes(Request(URL), limit=128, opener=self.opener, **kwargs)

    def test_public_403_then_success_recovers_without_polluting_json_stdout(self):
        failure = self.error(403, {"Server": "cloudflare", "CF-Mitigated": "challenge"})
        self.assertEqual(self.fetch([failure, Response()], retry_forbidden=True), b"[]")
        self.sleep.assert_called_once_with(5)
        self.assertTrue(failure.closed)
        self.assertIn("https://releases.unraid.net/json", self.stderr.getvalue())
        self.assertIn("HTTP 403", self.stderr.getvalue())
        self.assertIn("CF-Mitigated='challenge'", self.stderr.getvalue())
        self.assertIn("attempt 2/3", self.stderr.getvalue())
        self.assertEqual(self.stdout.getvalue(), "")

    def test_persistent_public_403_stays_a_failure_after_three_attempts(self):
        failures = [self.error(403) for _ in range(3)]
        with self.assertRaises(HTTPError) as caught:
            self.fetch(failures, retry_forbidden=True)
        self.assertEqual(caught.exception.code, 403)
        self.assertIn("https://releases.unraid.net/json", str(caught.exception))
        self.assertIn("failed after 3 attempt(s)", str(caught.exception))
        self.assertEqual(self.opener.call_count, 3)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [5, 15])
        self.assertTrue(all(error.closed for error in failures))

    def test_permission_403_without_rate_limit_headers_does_not_retry(self):
        with self.assertRaises(HTTPError): self.fetch([self.error(403)])
        self.assertEqual(self.opener.call_count, 1)
        self.sleep.assert_not_called()

    def test_rate_limited_403_honors_retry_after(self):
        self.assertEqual(self.fetch([self.error(403, {"Retry-After": "12"}), Response()]), b"[]")
        self.sleep.assert_called_once_with(12)

    def test_rate_limit_reset_is_honored(self):
        headers = {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1040"}
        self.fetch([self.error(403, headers), Response()])
        self.sleep.assert_called_once_with(40)

    def test_long_rate_limit_delay_fails_without_retrying_early(self):
        for headers in ({"Retry-After": "3600"},
                        {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "4600"}):
            with self.subTest(headers=headers), self.assertRaises(HTTPError):
                self.fetch([self.error(403, headers)])
            self.assertEqual(self.opener.call_count, 1)
        self.sleep.assert_not_called()

    def test_retry_after_http_date_is_supported(self):
        self.fetch([self.error(429, {"Retry-After": formatdate(1020, usegmt=True)}), Response()])
        self.sleep.assert_called_once_with(20)

    def test_bad_retry_after_uses_bounded_backoff(self):
        self.fetch([self.error(503, {"Retry-After": "invalid"}), Response()])
        self.sleep.assert_called_once_with(5)

    def test_transient_http_statuses_retry(self):
        for code in sorted(http.RETRY_STATUSES):
            with self.subTest(code=code):
                self.assertEqual(self.fetch([self.error(code), Response()]), b"[]")
                self.assertEqual(self.opener.call_count, 2)

    def test_not_found_and_authentication_errors_keep_their_status(self):
        for code in (400, 401, 404, 422):
            with self.subTest(code=code), self.assertRaises(HTTPError) as caught:
                self.fetch([self.error(code)], retry_forbidden=True)
            self.assertEqual(caught.exception.code, code)
            self.assertEqual(self.opener.call_count, 1)
        self.sleep.assert_not_called()

    def test_transport_errors_retry_without_partial_output(self):
        for error in (TimeoutError(), URLError("temporary DNS failure"),
                      ConnectionResetError(), IncompleteRead(b"partial", 30)):
            with self.subTest(error=type(error).__name__):
                self.assertEqual(self.fetch([error, Response()]), b"[]")
                self.assertEqual(self.opener.call_count, 2)
        self.assertEqual(self.stdout.getvalue(), "")

    def test_transport_failure_after_budget_includes_source(self):
        with self.assertRaisesRegex(OSError, "releases.unraid.net/json.*failed after 3"):
            self.fetch([TimeoutError() for _ in range(3)])
        self.assertEqual(self.opener.call_count, 3)

    def test_tls_verification_errors_are_not_weakened_or_retried(self):
        for error in (ssl.SSLCertVerificationError(), URLError(ssl.SSLCertVerificationError())):
            with self.subTest(error=type(error).__name__), self.assertRaisesRegex(OSError, "TLS certificate"):
                self.fetch([error])
        self.sleep.assert_not_called()

    def test_oversized_response_is_closed_and_not_retried(self):
        response = Response(b"x" * 129)
        with self.assertRaisesRegex(ValueError, "exceeds 128"):
            self.fetch([response])
        self.assertTrue(response.closed)
        self.sleep.assert_not_called()

    def test_official_metadata_cross_host_redirect_is_rejected(self):
        response = Response(url="https://wrong.example/json")
        with self.assertRaisesRegex(ValueError, "cross-host"):
            self.fetch([response], same_host=True)
        self.assertTrue(response.closed)
        self.sleep.assert_not_called()

    def test_success_preserves_timeout_and_headers(self):
        request = Request(URL, headers={"Authorization": "Bearer test-secret"})
        opener = Mock(return_value=Response())
        self.assertEqual(http.get_bytes(request, limit=128, timeout=60, opener=opener), b"[]")
        opener.assert_called_once_with(request, timeout=60)
        self.assertEqual(request.headers["Authorization"], "Bearer test-secret")
        self.assertNotIn("test-secret", self.stderr.getvalue())

    def test_logs_do_not_expose_credentials_queries_fragments_or_error_bodies(self):
        secret_url = "https://user:password@mirror.example/list?token=secret#private"
        request = Request(secret_url, headers={"Authorization": "Bearer auth-secret"})
        with self.assertRaises(HTTPError) as caught:
            http.get_bytes(request, limit=128, opener=Mock(side_effect=self.error(403)))
        text = self.stderr.getvalue() + str(caught.exception)
        for secret in ("user", "password", "secret", "private", "untrusted error body"):
            self.assertNotIn(secret, text)
        self.assertIn("https://mirror.example/list", text)

    def test_post_and_get_with_body_are_rejected_before_network_access(self):
        for request in (Request(URL, method="POST"), Request(URL, data=b"{}", method="GET")):
            opener = Mock()
            with self.assertRaisesRegex(ValueError, "bodyless GET"):
                http.get_bytes(request, limit=128, opener=opener)
            opener.assert_not_called()


if __name__ == "__main__":
    unittest.main()
