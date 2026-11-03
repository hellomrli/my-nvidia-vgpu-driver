"""Bounded, observable retries for read-only upstream metadata requests."""

from email.utils import parsedate_to_datetime
from http.client import IncompleteRead, RemoteDisconnected
import ssl
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import urlopen


ATTEMPTS = 3
DELAYS = (5, 15)
MAX_RETRY_DELAY = 60
RETRY_STATUSES = {408, 425, 429, 500, 502, 503, 504}


def display_url(url):
    parts = urlsplit(url)
    # Queries and userinfo can contain credentials on a configured mirror.
    return urlunsplit((parts.scheme, parts.netloc.rsplit("@", 1)[-1], parts.path, "", ""))


def log(message):
    print(f"[http] {message}", file=sys.stderr)


def wait_seconds(headers, default):
    requested = headers.get("Retry-After")
    try:
        if requested is not None:
            if requested.isdigit():
                seconds = float(requested)
            else:
                seconds = parsedate_to_datetime(requested).timestamp() - time.time()
        elif headers.get("X-RateLimit-Remaining") == "0" and headers.get("X-RateLimit-Reset"):
            seconds = float(headers["X-RateLimit-Reset"]) - time.time()
        else:
            return default
        seconds = max(default, seconds)
        # Do not retry earlier than requested or stall the job for a quota reset.
        return seconds if seconds <= MAX_RETRY_DELAY else None
    except (TypeError, ValueError, OverflowError):
        return default


def get_bytes(request, *, limit, timeout=45, same_host=False,
              retry_forbidden=False, opener=None):
    if request.get_method() != "GET" or request.data is not None:
        raise ValueError("Metadata retries only support bodyless GET requests")
    open_request = opener or urlopen
    label = "GET " + display_url(request.full_url)
    for attempt in range(1, ATTEMPTS + 1):
        log(f"{label} (attempt {attempt}/{ATTEMPTS})")
        try:
            with open_request(request, timeout=timeout) as response:
                if same_host and urlsplit(response.url).hostname != urlsplit(request.full_url).hostname:
                    raise ValueError(f"{label}: unexpected cross-host redirect")
                data = response.read(limit + 1)
                if len(data) > limit:
                    raise ValueError(f"{label}: response exceeds {limit} bytes")
                log(f"{label}: HTTP {response.status}, {len(data)} bytes")
                return data
        except HTTPError as error:
            headers = error.headers or {}
            details = [f"{label}: HTTP {error.code}"]
            for name in ("Server", "CF-Mitigated", "Retry-After", "X-RateLimit-Remaining", "X-RateLimit-Reset"):
                if headers.get(name) is not None:
                    details.append(f"{name}={headers[name]!r}")
            detail = "; ".join(details)
            error.close()
            # Public catalogs can intermittently reject a shared runner IP.
            # Authenticated 403s only retry when rate-limit headers identify them.
            rate_limited = headers.get("Retry-After") is not None or headers.get("X-RateLimit-Remaining") == "0"
            retry = error.code in RETRY_STATUSES or error.code == 403 and (retry_forbidden or rate_limited)
            delay = wait_seconds(headers, DELAYS[attempt - 1]) if retry and attempt < ATTEMPTS else None
            if delay is None:
                error.msg = f"{detail}; metadata check failed after {attempt} attempt(s)"
                log(error.msg)
                raise
            log(f"{detail}; retrying in {delay:g}s")
        except (URLError, TimeoutError, ConnectionError, IncompleteRead,
                RemoteDisconnected, ssl.SSLCertVerificationError) as error:
            # Keep TLS verification failures visible instead of retrying or
            # relaxing verification. Never print request headers or raw bodies.
            certificate_error = isinstance(getattr(error, "reason", error), ssl.SSLCertVerificationError)
            kind = "TLS certificate verification failed" if certificate_error else type(error).__name__
            detail = f"{label}: {kind}"
            if attempt == ATTEMPTS or certificate_error:
                raise OSError(f"{detail}; metadata check failed after {attempt} attempt(s)") from error
            delay = DELAYS[attempt - 1]
            log(f"{detail}; retrying in {delay}s")
        time.sleep(delay)
