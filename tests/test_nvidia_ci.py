from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from threading import Thread
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen as real_urlopen


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nvidia_ci", ROOT / "scripts/nvidia-ci.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)
K58, K59, K60 = (f"6.18.{number}-Unraid" for number in (58, 59, 60))
DIR16 = "NVIDIA-GRID-Linux-KVM-535.309.01-539.72"
DIR19 = "NVIDIA-GRID-Linux-KVM-580.178.05-580.178.04-582.78"
LINES = [ci.driver_line("16.14", DIR16), ci.driver_line("19.6", DIR19)]


def resolved(kernels=(K58, K60)):
    return {"stable": {"version": "7.3.4", "kernel_release": kernels[0]},
            "next": {"version": "7.4.0-rc.2", "kernel_release": kernels[0]},
            "ich777": {"kernel_release": kernels[-1]}, "kernel_releases": list(kernels)}


def asset(name, size=100, state="uploaded"):
    return {"name": name, "size": size, "state": state}


def pair(version="535.309.01", kernel=K58, number=1):
    name = ci.package_name(version, kernel, number)
    return [asset(name), asset(name + ".md5")]


class FakeGitHub:
    def __init__(self, by_kernel=None):
        self.by_kernel = deepcopy(by_kernel or {})
        self.releases = {kernel: {"id": i + 1, "tag_name": kernel, "draft": False,
                                  "body": "Keep existing release notes"}
                         for i, kernel in enumerate(self.by_kernel)}
        self.release_calls = []
        self.requests = []

    def release(self, kernel):
        self.release_calls.append(kernel)
        return self.releases.get(kernel)

    def assets(self, release):
        return deepcopy(self.by_kernel[release["tag_name"]]) if release else []

    def request(self, method, path, body=None, upload=None):
        self.requests.append((method, path, body, upload))
        if method == "POST" and path == "releases":
            kernel = body["tag_name"]
            self.releases[kernel] = {**body, "id": len(self.releases) + 1, "draft": False}
            self.by_kernel[kernel] = []
            return self.releases[kernel]
        if method == "POST" and upload is not None:
            release_id = int(path.split("/")[1])
            kernel = next(k for k, r in self.releases.items() if r["id"] == release_id)
            name = parse_qs(urlparse(path).query)["name"][0]
            result = asset(name, upload.stat().st_size)
            self.by_kernel[kernel].append(result)
            return result
        raise AssertionError(f"Unexpected API request: {method} {path}")


class MirrorTests(unittest.TestCase):
    def setUp(self):
        self.tree = {"/vGPU": ["16.9", "16.14", "19.5", "19.6", "20.0"],
                     "/vGPU/16.14": [DIR16], "/vGPU/19.6": [DIR19]}

    def fetch(self, url):
        directory = parse_qs(urlparse(url).query)["path"][0]
        return {"code": 200, "data": {"content": [
            {"name": name, "is_dir": True} for name in self.tree[directory]]}}

    def lines(self, majors=("16", "19")):
        return ci.resolve_lines(list(majors), self.fetch, "https://mirror.test/list", "/vGPU")

    def test_two_and_three_version_layouts(self):
        self.assertEqual(self.lines(), LINES)
        self.assertEqual(LINES[1]["windows_version"], "582.78")

    def test_branches_and_packages_are_sorted_numerically(self):
        self.tree["/vGPU/16.14"] = ["NVIDIA-GRID-Linux-KVM-535.9.0-539.72",
                                    "NVIDIA-GRID-Linux-KVM-535.310.01-539.72", DIR16]
        self.tree["/vGPU"].reverse()
        self.assertEqual(self.lines()[0]["driver_version"], "535.310.01")

    def test_package_order_uses_windows_version_as_tiebreaker(self):
        self.tree["/vGPU/16.14"] = [DIR16, DIR16.replace("539.72", "539.100")]
        self.assertEqual(self.lines()[0]["windows_version"], "539.100")

    def test_one_supported_series_can_be_selected(self):
        self.assertEqual(self.lines(("19",)), [LINES[1]])

    def test_missing_selected_series_is_an_error(self):
        self.tree["/vGPU"] = ["16.14"]
        with self.assertRaisesRegex(ValueError, "Missing vGPU 19"):
            self.lines()

    def test_empty_latest_branch_does_not_fall_back(self):
        self.tree["/vGPU/19.6"] = []
        with self.assertRaisesRegex(ValueError, "Missing NVIDIA"):
            self.lines()

    def test_invalid_or_duplicate_series_rejected(self):
        for majors in ([], ["16", "16"], ["20"], ["16", "oops"]):
            with self.subTest(majors=majors), self.assertRaises(ValueError):
                self.lines(majors)

    def test_invalid_mirror_response_is_not_an_empty_catalog(self):
        for data in (None, [], {}, {"code": 500, "data": {"content": []}},
                     {"code": 200, "data": {"content": None}},
                     {"code": 200, "data": {"content": [{"name": "16.14", "is_dir": 1}]}}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                ci.directory_names(data)

    def test_files_are_not_branches(self):
        result = ci.directory_names({"code": 200, "data": {"content": [
            {"name": "19.6", "is_dir": False}, {"name": "16.14", "is_dir": True}]}})
        self.assertEqual(result, ["16.14"])

    def test_wrong_driver_family_or_untrusted_path_rejected(self):
        for branch, directory in (("16.14", DIR19), ("19.6", DIR16),
                                  ("19.6", DIR19.replace("580.178.04", "535.1.0")),
                                  ("20.0", DIR19), ("16.14/../", DIR16),
                                  ("16.14", DIR16 + "/../../")):
            with self.subTest(branch=branch, directory=directory), self.assertRaises(ValueError):
                ci.driver_line(branch, directory)

    def test_network_failure_propagates(self):
        with self.assertRaises(OSError):
            ci.resolve_lines(["16", "19"], lambda _: (_ for _ in ()).throw(OSError("offline")))


class PackageTests(unittest.TestCase):
    def test_only_current_kernel_by_series_cross_product_is_checked(self):
        api = FakeGitHub({K59: pair(kernel=K59)})
        result = ci.check_updates(resolved(), LINES, api)
        self.assertEqual(api.release_calls, [K58, K60])
        self.assertEqual({(b["kernel_release"], b["major"]) for b in result["builds"]},
                         {(kernel, major) for kernel in (K58, K60) for major in ("16", "19")})
        self.assertTrue(result["build_needed"])

    def test_three_distinct_targets_cover_six_combinations(self):
        result = ci.check_updates(resolved((K58, K59, K60)), LINES, FakeGitHub())
        self.assertEqual(len(result["builds"]), 6)

    def test_both_current_series_complete_means_no_rebuild(self):
        api = FakeGitHub({k: pair(kernel=k) + pair("580.178.05", k) for k in (K58, K60)})
        result = ci.check_updates(resolved(), LINES, api)
        self.assertFalse(result["build_needed"])
        self.assertEqual(result["builds"], [])
        self.assertEqual(len(result["decisions"]), 4)

    def test_only_missing_series_and_kernel_gets_built(self):
        api = FakeGitHub({K58: pair() + pair("580.178.05", K58), K60: pair(kernel=K60)})
        result = ci.check_updates(resolved(), LINES, api)
        self.assertEqual([(b["kernel_release"], b["major"]) for b in result["builds"]], [(K60, "19")])

    def test_complete_package_requires_exact_version_kernel_and_checksum(self):
        name = pair()[0]["name"]
        for assets in ([], [asset(name)], [asset(name + ".md5")],
                       pair("535.309.010"), pair(kernel=K59),
                       [asset(name), asset(name + ".md5", size=0)],
                       [asset(name, state="new"), asset(name + ".md5")],
                       [asset(name, size=0), asset(name + ".md5")],
                       [asset(name), asset(name + ".sha256")],
                       [asset(name.replace("-1.txz", "-0.txz")), asset(name.replace("-1.txz", "-0.txz.md5"))]):
            with self.subTest(assets=assets):
                self.assertIsNone(ci.complete_package(assets, "535.309.01", K58))

    def test_newest_complete_build_uses_numeric_order(self):
        assets = pair(number=9) + pair(number=10) + [asset(ci.package_name("535.309.01", K58, 11))]
        self.assertEqual(ci.complete_package(assets, "535.309.01", K58), pair(number=10)[0]["name"])

    def test_auto_build_skips_orphaned_assets_even_if_unuploaded(self):
        assets = pair() + [asset(ci.package_name("535.309.01", K58, 7) + ".md5", state="new", size=0)]
        self.assertEqual(ci.next_build(assets, "535.309.01", K58), 8)
        self.assertEqual(ci.next_build([], "535.309.01", K58), 1)

    def test_build_numbers_ignore_other_kernels_and_versions(self):
        assets = pair(kernel=K59, number=100) + pair("580.178.05", number=100)
        self.assertEqual(ci.next_build(assets, "535.309.01", K58), 1)

    def test_explicit_build_number_must_increase_and_be_positive(self):
        for number in ("0", "-1", "1", "01", "2", "2.0", "3\ninjected=true"):
            with self.subTest(number=number), self.assertRaises(ValueError):
                ci.next_build(pair(number=2), "535.309.01", K58, number)
        self.assertEqual(ci.next_build(pair(number=2), "535.309.01", K58, "3"), 3)

    def test_package_name_rejects_invalid_components(self):
        for version, kernel, number in (("../535", K58, 1), ("535.1", "../kernel", 1),
                                         ("535.1", K58, 0), ("535.1", K58, True)):
            with self.subTest(version=version, kernel=kernel, number=number), self.assertRaises(ValueError):
                ci.package_name(version, kernel, number)


class PlanTests(unittest.TestCase):
    def test_latest_resolves_to_ich_kernel_not_a_stale_default(self):
        for value in ("", "latest", K60):
            plan = ci.plan_build(resolved(), LINES[0], value, FakeGitHub())
            self.assertEqual(plan["kernel_release"], K60)
            self.assertEqual(plan["package_build"], 1)
            self.assertTrue(plan["build"])

    def test_manual_current_stable_kernel_is_allowed(self):
        plan = ci.plan_build(resolved(), LINES[1], K58, FakeGitHub())
        self.assertEqual(plan["package"], pair("580.178.05")[0]["name"])

    def test_manual_historical_kernel_rejected_even_if_force_requested(self):
        api = FakeGitHub()
        for value in (K59, "6.18.44-Unraid", "bad\noutput=true"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "not a current"):
                ci.plan_build(resolved(), LINES[0], value, api, force=True)
        self.assertEqual(api.release_calls, [])

    def test_queued_build_rechecks_complete_package_and_skips(self):
        plan = ci.plan_build(resolved(), LINES[0], K58, FakeGitHub({K58: pair()}))
        self.assertFalse(plan["build"])
        self.assertNotIn("package_build", plan)

    def test_explicit_rebuild_preserves_name_of_existing_package(self):
        api = FakeGitHub({K58: pair(number=3)})
        plan = ci.plan_build(resolved(), LINES[0], K58, api, force=True)
        self.assertEqual(plan["package_build"], 4)
        self.assertTrue(plan["build"])
        self.assertEqual(api.by_kernel[K58], pair(number=3))

    def test_incomplete_package_requires_new_build_number(self):
        api = FakeGitHub({K58: [pair(number=4)[1]]})
        plan = ci.plan_build(resolved(), LINES[0], K58, api)
        self.assertEqual(plan["package_build"], 5)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.api = FakeGitHub()
        self.plan = ci.plan_build(resolved(), LINES[0], K58, self.api)
        self.package = self.directory / self.plan["package"]
        self.package.write_bytes(b"test package content")
        self.checksum = self.directory / (self.package.name + ".md5")
        self.checksum.write_text(f"{ci.file_hash(self.package)}  {self.package.name}\n")

    def test_creates_release_and_publishes_checksum_before_package(self):
        ci.publish(self.plan, self.api, self.directory)
        self.assertEqual([r[0] for r in self.api.requests], ["POST", "POST", "POST"])
        self.assertEqual([r[3] for r in self.api.requests if r[3]], [self.checksum, self.package])
        self.assertEqual(ci.complete_package(self.api.by_kernel[K58], "535.309.01", K58), self.package.name)

    def test_existing_release_notes_and_other_packages_are_unchanged(self):
        self.api = FakeGitHub({K58: pair("580.178.05")})
        before = deepcopy(self.api.releases[K58])
        ci.publish(self.plan, self.api, self.directory)
        self.assertEqual(self.api.releases[K58], before)
        self.assertEqual(self.api.by_kernel[K58][:2], pair("580.178.05"))
        self.assertEqual(len(self.api.requests), 2)

    def test_only_exact_planned_artifact_is_uploaded(self):
        (self.directory / "nvidia-wrong-version.txz").write_bytes(b"wrong")
        ci.publish(self.plan, self.api, self.directory)
        self.assertEqual([r[3].name for r in self.api.requests if r[3]],
                         [self.checksum.name, self.package.name])

    def test_missing_empty_or_different_package_is_rejected_before_api_writes(self):
        for mode in ("empty", "missing", "mismatch"):
            with self.subTest(mode=mode):
                if mode == "empty": self.package.write_bytes(b"")
                elif mode == "missing": self.package.unlink()
                else:
                    self.package.write_bytes(b"test package content")
                    self.plan["package"] = "unexpected.txz"
                with self.assertRaises(ValueError): ci.publish(self.plan, self.api, self.directory)
        self.assertEqual(self.api.requests, [])

    def test_bad_checksum_or_wrong_basename_is_rejected(self):
        digest = ci.file_hash(self.package)
        for text in ("", f"0000  {self.package.name}\n", f"{digest}  wrong.txz\n",
                     f"{digest}  {self.package.name}\nextra\n"):
            self.checksum.write_text(text)
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "MD5"):
                ci.publish(self.plan, self.api, self.directory)
        self.checksum.unlink()
        with self.assertRaisesRegex(ValueError, "MD5"): ci.publish(self.plan, self.api, self.directory)
        self.assertEqual(self.api.requests, [])

    def test_skipped_plan_cannot_publish(self):
        self.plan["build"] = False
        with self.assertRaisesRegex(ValueError, "skipped"):
            ci.publish(self.plan, self.api, self.directory)

    def test_existing_package_or_checksum_is_never_overwritten(self):
        for existing in pair():
            api = FakeGitHub({K58: [existing]})
            with self.subTest(existing=existing), self.assertRaisesRegex(ValueError, "already exists"):
                ci.publish(self.plan, api, self.directory)
            self.assertEqual(api.requests, [])

    def test_concurrent_series_can_create_same_release_safely(self):
        request = self.api.request
        def racing_create(method, path, body=None, upload=None):
            response = request(method, path, body, upload)
            if path == "releases":
                raise HTTPError("https://api.github.test", 422, "already exists", {}, None)
            return response
        with patch.object(self.api, "request", side_effect=racing_create):
            ci.publish(self.plan, self.api, self.directory)
        self.assertEqual(len(self.api.by_kernel[K58]), 2)

    def test_release_creation_error_without_a_release_is_not_ignored(self):
        for code in (422, 403, 500):
            error = HTTPError("https://api.github.test", code, "failure", {}, None)
            with self.subTest(code=code), patch.object(self.api, "request", side_effect=error):
                with self.assertRaises((ValueError, HTTPError)):
                    ci.publish(self.plan, self.api, self.directory)

    def test_failed_checksum_upload_never_exposes_a_package(self):
        self.api = FakeGitHub({K58: []})
        with patch.object(self.api, "request", return_value=asset(self.checksum.name, size=0)) as call:
            with self.assertRaisesRegex(ValueError, "Upload did not complete"):
                ci.publish(self.plan, self.api, self.directory)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(call.call_args.kwargs["upload"], self.checksum)

    def test_failed_package_upload_leaves_a_detectable_incomplete_build(self):
        request = self.api.request
        def fail_package(method, path, body=None, upload=None):
            if upload == self.package: raise OSError("upload failed")
            return request(method, path, body, upload)
        with patch.object(self.api, "request", side_effect=fail_package), self.assertRaises(OSError):
            ci.publish(self.plan, self.api, self.directory)
        self.assertIsNone(ci.complete_package(self.api.by_kernel[K58], "535.309.01", K58))
        self.assertEqual(ci.next_build(self.api.by_kernel[K58], "535.309.01", K58), 2)


class GitHubTests(unittest.TestCase):
    def setUp(self):
        self.api = ci.GitHub("owner/repo", "test-token")

    def test_missing_token_or_invalid_repository_rejected(self):
        for repo, token in (("owner/repo", ""), ("owner/repo/../../", "test-token")):
            with self.assertRaises(ValueError): ci.GitHub(repo, token)

    def test_only_404_is_a_missing_release(self):
        for code in (404, 403, 429, 500):
            error = HTTPError("https://api.github.test", code, "failure", {}, None)
            with self.subTest(code=code), patch.object(self.api, "request", side_effect=error):
                if code == 404: self.assertIsNone(self.api.release(K58))
                else:
                    with self.assertRaises(HTTPError): self.api.release(K58)

    def test_release_response_must_match_published_tag(self):
        good = {"id": 1, "tag_name": K58, "draft": False}
        for data in ({}, [], {**good, "tag_name": K59}, {**good, "draft": True},
                     {**good, "id": True}, {**good, "id": -1}):
            with self.subTest(data=data), patch.object(self.api, "request", return_value=data):
                with self.assertRaises(ValueError): self.api.release(K58)

    def test_assets_are_paginated(self):
        first = [asset(f"unrelated-{number}") for number in range(100)]
        with patch.object(self.api, "request", side_effect=[first, pair()]) as call:
            assets = self.api.assets({"id": 7})
        self.assertEqual(len(assets), 102)
        self.assertIn("page=2", call.call_args.args[1])
        self.assertIsNotNone(ci.complete_package(assets, "535.309.01", K58))

    def test_invalid_asset_responses_fail_closed(self):
        for data in ({}, None, [None], [asset("pkg", size=-1)], [asset("pkg", size=True)],
                     [{"name": "pkg", "size": 1}]):
            with self.subTest(data=data), patch.object(self.api, "request", return_value=data):
                with self.assertRaises(ValueError): self.api.assets({"id": 1})

    def test_json_request_uses_authenticated_api_host(self):
        with patch.object(ci, "urlopen", return_value=io.BytesIO(b'{"id": 1}')) as call:
            self.assertEqual(self.api.request("POST", "releases", {"tag_name": K58}), {"id": 1})
        request = call.call_args.args[0]
        self.assertEqual(urlparse(request.full_url).netloc, "api.github.com")
        self.assertEqual(request.headers["Authorization"], "Bearer test-token")
        self.assertEqual(json.loads(request.data), {"tag_name": K58})

    def test_streamed_upload_sends_exact_length_and_bytes(self):
        received = {}
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received["length"] = int(self.headers["Content-Length"])
                received["transfer"] = self.headers.get("Transfer-Encoding")
                received["body"] = self.rfile.read(received["length"])
                self.send_response(201)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"state": "uploaded"}')
            def log_message(self, *_): pass
        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def local_upload(request, timeout):
            self.assertEqual(urlparse(request.full_url).netloc, "uploads.github.com")
            self.assertTrue(hasattr(request.data, "read"))
            received["stream"] = request.data
            local = Request(f"http://127.0.0.1:{server.server_port}/upload", data=request.data,
                            headers=dict(request.header_items()), method=request.get_method())
            return real_urlopen(local, timeout=timeout)
        try:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "package.txz"
                data = bytes(range(256)) * 1024
                path.write_bytes(data)
                with patch.object(ci, "urlopen", side_effect=local_upload):
                    self.assertEqual(self.api.request("POST", "releases/1/assets?name=package.txz", upload=path),
                                     {"state": "uploaded"})
            self.assertEqual(received["length"], len(data))
            self.assertEqual(received["body"], data)
            self.assertIsNone(received["transfer"])
            self.assertTrue(received["stream"].closed)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_failed_upload_also_closes_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "package.txz"
            path.write_bytes(b"test")
            with patch.object(ci, "urlopen", side_effect=OSError("offline")) as call:
                with self.assertRaises(OSError): self.api.request("POST", "assets", upload=path)
            self.assertTrue(call.call_args.args[0].data.closed)


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.api = FakeGitHub()
        self.env = {"GITHUB_TOKEN": "test-token", "GITHUB_REPOSITORY": "owner/repo",
                    "VERSION": "535.309.01", "ALIST_WINVER": "539.72", "ALIST_VGPU_BRANCH": "16.14",
                    "GITHUB_OUTPUT": str(self.directory / "output"),
                    "GITHUB_STEP_SUMMARY": str(self.directory / "summary")}

    def run_command(self, command):
        output = io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), patch.object(ci, "ROOT", self.directory), \
                patch.object(ci, "GitHub", return_value=self.api), \
                patch.object(ci.targets, "resolve", return_value=resolved()), \
                patch.object(ci, "resolve_lines", return_value=LINES), \
                patch("sys.argv", ["nvidia-ci.py", command]), redirect_stdout(output), redirect_stderr(io.StringIO()):
            ci.main()
        return json.loads(output.getvalue()) if output.getvalue() else None

    def test_check_emits_all_targets_and_decisions(self):
        result = self.run_command("check")
        self.assertEqual(result["kernel_releases"], [K58, K60])
        self.assertEqual(len(result["builds"]), 4)
        self.assertIn("7.3.4", (self.directory / "summary").read_text())
        self.assertIn("7.4.0-rc.2", (self.directory / "summary").read_text())

    def test_plan_records_exact_artifact_and_resolved_kernel_outputs(self):
        result = self.run_command("plan")
        self.assertEqual(json.loads((self.directory / "out/build-plan.json").read_text()), result)
        self.assertIn(f"kernel_release={K60}\n", (self.directory / "output").read_text())
        self.assertIn("package_build=1\n", (self.directory / "output").read_text())

    def test_repeated_plan_reports_skip_without_reusing_a_build_number(self):
        self.api = FakeGitHub({K60: pair(kernel=K60)})
        self.assertFalse(self.run_command("plan")["build"])
        self.assertIn("build=false\n", (self.directory / "output").read_text())
        self.assertIn("package_build=\n", (self.directory / "output").read_text())

    def test_version_directory_mismatch_and_bad_force_fail_before_outputs(self):
        for extra in ({"ALIST_PKG_DIR": DIR19}, {"FORCE_REBUILD": "yes"},
                      {"VERSION": "535.309.01\ninjected=true"}):
            old = deepcopy(self.env)
            self.env.update(extra)
            with self.subTest(extra=extra), self.assertRaises(ValueError): self.run_command("plan")
            self.assertFalse((self.directory / "output").exists())
            self.env = old

    def test_workflows_gate_builds_and_lock_canonical_kernel_version_pair(self):
        workflow = (ROOT / ".github/workflows/build-nvidia.yml").read_text()
        check = (ROOT / ".github/workflows/check-updates.yml").read_text()
        self.assertIn("group: nvidia-vgpu-${{ needs.plan.outputs.kernel_release }}-${{ inputs.driver_version }}", workflow)
        self.assertEqual(workflow.count("python3 scripts/nvidia-ci.py plan"), 2)
        self.assertEqual(workflow.count("if: steps.plan.outputs.build == 'true'"), 2)
        self.assertIn("if: needs.plan.outputs.build == 'true'", workflow)
        self.assertIn("python3 scripts/nvidia-ci.py publish", workflow)
        self.assertNotIn("DELETE", workflow)
        self.assertIn('package_build:"auto"', check)
        self.assertIn("jq -c '.kernel_releases'", check)
        self.assertNotIn("6.18.44-Unraid", workflow)


if __name__ == "__main__":
    unittest.main()
