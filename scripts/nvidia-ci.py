#!/usr/bin/env python3
"""Plan current-kernel NVIDIA builds and publish complete, immutable packages."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("unraid_targets", ROOT / "scripts/resolve-unraid.py")
targets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(targets)
SERIES = {"16": "535", "19": "580"}
VERSION = r"[0-9]+(?:\.[0-9]+)+"
KERNEL = r"[0-9]+\.[0-9]+\.[0-9]+-Unraid"


def require(value, pattern, label):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ValueError(f"Invalid {label}: {value!r}")
    return value


def log(message):
    print(f"[nvidia-ci] {message}", file=sys.stderr)


def fetch_json(url):
    request = Request(url, headers={"User-Agent": "my-nvidia-vgpu-driver/update-check"})
    with urlopen(request, timeout=45) as response:
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise ValueError("Mirror catalog is unexpectedly large")
        return json.loads(data)


def directory_names(data):
    if (not isinstance(data, dict) or data.get("code") != 200
            or not isinstance(data.get("data"), dict)
            or not isinstance(data["data"].get("content"), list)):
        raise ValueError("Invalid mirror directory response; not an empty/up-to-date catalog")
    names = []
    for item in data["data"]["content"]:
        if (not isinstance(item, dict) or not isinstance(item.get("name"), str)
                or type(item.get("is_dir")) is not bool):
            raise ValueError("Invalid mirror directory entry")
        if item["is_dir"]:
            names.append(item["name"])
    return names


def version_key(value):
    return tuple(int(part) for part in value.split("."))


def validate_release(release, kernel):
    if (not isinstance(release, dict) or type(release.get("id")) is not int
            or release["id"] < 1 or release.get("draft") is not False
            or release.get("tag_name") != kernel):
        raise ValueError("Invalid/unpublished driver release")
    return release


def driver_line(branch, directory):
    require(branch, r"[0-9]+\.[0-9]+", "vGPU branch")
    major = branch.split(".")[0]
    if major not in SERIES:
        raise ValueError(f"Unsupported vGPU series: {major}")
    match = re.fullmatch(rf"NVIDIA-GRID-Linux-KVM-({VERSION})-({VERSION})(?:-({VERSION}))?", directory)
    if not match:
        raise ValueError(f"Invalid NVIDIA package directory: {directory!r}")
    driver, grid_or_windows, windows = match.groups()
    if driver.split(".")[0] != SERIES[major]:
        raise ValueError("Driver family does not match vGPU series")
    if windows and grid_or_windows.split(".")[0] != SERIES[major]:
        raise ValueError("GRID driver family does not match vGPU series")
    return {"major": major, "vgpu_branch": branch, "driver_version": driver,
            "windows_version": windows or grid_or_windows, "alist_pkg_dir": directory}


def resolve_lines(majors, fetch=fetch_json, api=None, path=None):
    if not majors or len(set(majors)) != len(majors) or any(m not in SERIES for m in majors):
        raise ValueError("VGPU_MAJORS must contain distinct supported series: 16 and/or 19")
    api = api or os.environ.get("ALIST_API", "https://alist.homelabproject.cc/api/fs/list")
    path = path or os.environ.get("VGPU_PATH", "/foxipan/vGPU")
    def listing(directory):
        return directory_names(fetch(api + "?" + urlencode({"path": directory})))
    branches = listing(path)
    lines = []
    for major in majors:
        candidates = [b for b in branches if re.fullmatch(re.escape(major) + r"\.[0-9]+", b)]
        if not candidates:
            raise ValueError(f"Missing vGPU {major}.x branch; refusing to silently skip this series")
        branch = max(candidates, key=version_key)
        packages = [driver_line(branch, name) for name in listing(path + "/" + branch)
                    if name.startswith("NVIDIA-GRID-Linux-KVM-")]
        if not packages:
            raise ValueError(f"Missing NVIDIA package directory under {branch}")
        line = max(packages, key=lambda item: (version_key(item["driver_version"]),
                                               version_key(item["windows_version"])))
        log(f"vGPU {major}: {branch}, driver {line['driver_version']}")
        lines.append(line)
    return lines


class GitHub:
    def __init__(self, repository, token):
        self.repository = require(repository, r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", "repository")
        if not token:
            raise ValueError("GITHUB_TOKEN or GH_TOKEN is required")
        self.token = token

    def request(self, method, path, body=None, upload=None):
        host = "uploads.github.com" if upload is not None else "api.github.com"
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "my-nvidia-vgpu-driver/ci"}
        data = json.dumps(body).encode() if body is not None else None
        if body is not None:
            headers["Content-Type"] = "application/json"
        stream = None
        try:
            if upload is not None:
                stream = upload.open("rb")
                data = stream
                headers.update({"Content-Type": "application/octet-stream",
                                "Content-Length": str(upload.stat().st_size)})
            request = Request(f"https://{host}/repos/{self.repository}/{path}", data=data,
                              headers=headers, method=method)
            with urlopen(request, timeout=600 if upload is not None else 60) as response:
                return json.load(response)
        finally:
            if stream is not None:
                stream.close()

    def release(self, kernel):
        require(kernel, KERNEL, "kernel release")
        try:
            release = self.request("GET", f"releases/tags/{quote(kernel, safe='')}")
        except HTTPError as error:
            error.close()
            if error.code == 404:
                return None
            raise
        return validate_release(release, kernel)

    def assets(self, release):
        if release is None:
            return []
        assets, page = [], 1
        while True:
            batch = self.request("GET", f"releases/{release['id']}/assets?per_page=100&page={page}")
            if not isinstance(batch, list):
                raise ValueError("Invalid release assets response")
            for asset in batch:
                if (not isinstance(asset, dict) or not isinstance(asset.get("name"), str)
                        or not isinstance(asset.get("state"), str)
                        or type(asset.get("size")) is not int or asset["size"] < 0):
                    raise ValueError("Invalid release asset")
            assets.extend(batch)
            if len(batch) < 100:
                return assets
            page += 1


def package_name(version, kernel, number):
    require(version, VERSION, "driver version")
    require(kernel, KERNEL, "kernel release")
    if type(number) is not int or number < 1:
        raise ValueError("Package build must be a positive integer")
    return f"nvidia-{version}-{kernel}-{number}.txz"


def complete_package(assets, version, kernel):
    prefix = package_name(version, kernel, 1).rsplit("-", 1)[0] + "-"
    pattern = re.compile(re.escape(prefix) + r"([1-9][0-9]*)\.txz")
    uploaded = {a["name"] for a in assets if a["state"] == "uploaded" and a["size"] > 0}
    complete = [(int(match[1]), name) for name in uploaded
                if (match := pattern.fullmatch(name)) and name + ".md5" in uploaded]
    return max(complete)[1] if complete else None


def next_build(assets, version, kernel, requested="auto"):
    prefix = package_name(version, kernel, 1).rsplit("-", 1)[0] + "-"
    pattern = re.compile(re.escape(prefix) + r"([0-9]+)\.txz(?:\.md5|\.sha256)?")
    numbers = [int(match[1]) for a in assets if (match := pattern.fullmatch(a["name"]))]
    highest = max(numbers, default=0)
    if requested in ("", "auto"):
        return highest + 1
    number = int(require(requested, r"[1-9][0-9]*", "package build"))
    if number <= highest:
        raise ValueError(f"Package build must exceed existing build {highest}; use auto")
    return number


def check_updates(resolved, lines, api):
    kernels = resolved["kernel_releases"]
    builds, decisions = [], []
    for kernel in kernels:
        assets = api.assets(api.release(kernel))
        for line in lines:
            package = complete_package(assets, line["driver_version"], kernel)
            state = {**line, "kernel_release": kernel, "package": package or ""}
            state["reason"] = "Complete matching package already published" if package else "Missing complete package and checksum"
            decisions.append(state)
            log(f"{kernel} / vGPU {line['major']}: {state['reason']}")
            if not package:
                builds.append({**line, "kernel_release": kernel, "reason": state["reason"]})
    return {"targets": resolved, "kernel_releases": kernels, "lines": lines,
            "build_needed": bool(builds), "builds": builds, "decisions": decisions}


def plan_build(resolved, line, kernel_input, api, force=False, requested="auto"):
    kernel = resolved["ich777"]["kernel_release"] if kernel_input in ("", "latest") else kernel_input
    if kernel not in resolved["kernel_releases"]:
        raise ValueError(f"{kernel} is not a current stable, public prerelease or latest ich777 kernel")
    version = line["driver_version"]
    assets = api.assets(api.release(kernel))
    complete = complete_package(assets, version, kernel)
    if complete and not force:
        return {"build": False, "reason": "Complete matching package already published",
                "kernel_release": kernel, "package": complete}
    number = next_build(assets, version, kernel, requested)
    return {"build": True, "reason": "Requested rebuild" if force else "Missing complete package",
            "kernel_release": kernel, "package_build": number, "line": line,
            "package": package_name(version, kernel, number)}


def file_hash(path):
    digest = hashlib.md5()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def publish(plan, api, directory):
    if plan.get("build") is not True:
        raise ValueError("Refusing to publish a skipped build")
    kernel = plan["kernel_release"]
    name = package_name(plan["line"]["driver_version"], kernel, plan["package_build"])
    if name != plan["package"]:
        raise ValueError("Package does not match the build plan")
    package, checksum = directory / name, directory / (name + ".md5")
    if not package.is_file() or package.stat().st_size == 0:
        raise ValueError("Missing built package")
    if not checksum.is_file() or checksum.read_text() != f"{file_hash(package)}  {name}\n":
        raise ValueError("Package MD5 is missing or does not match")
    release = api.release(kernel)
    if release is None:
        try:
            release = api.request("POST", "releases", {
                "tag_name": kernel, "name": f"NVIDIA vGPU (Merged) for {kernel}",
                "body": f"Kernel-matched NVIDIA vGPU (Merged) packages for {kernel}. Select the series supported by your GPU."})
            validate_release(release, kernel)
        except HTTPError as error:
            error.close()
            if error.code != 422:
                raise
            release = api.release(kernel)
            if release is None:
                raise ValueError("Release creation failed")
    names = {a["name"] for a in api.assets(release)}
    if names.intersection((name, name + ".md5")):
        raise ValueError("Release asset already exists; re-plan with a new build number")
    # Checksums first; never expose a new package without its checksum, and
    # never overwrite cached package names or delete historical assets.
    for path in (checksum, package):
        asset = api.request("POST", f"releases/{release['id']}/assets?name={quote(path.name, safe='')}", upload=path)
        if (not isinstance(asset, dict) or asset.get("name") != path.name
                or asset.get("state") != "uploaded" or asset.get("size") != path.stat().st_size):
            raise ValueError(f"Upload did not complete: {path.name}")
    log(f"Published {name}")


def summary(resolved, result=None):
    if not os.environ.get("GITHUB_STEP_SUMMARY"):
        return
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
        file.write("### Current NVIDIA kernel targets\n\n")
        for channel in ("stable", "next", "ich777"):
            item = resolved[channel]
            file.write(f"- {channel}: " + (f"{item.get('version', 'preparation')} / `{item['kernel_release']}`" if item else "no current public prerelease") + "\n")
        if result:
            for item in result.get("decisions", []):
                file.write(f"- `{item['kernel_release']}` / {item['major']}.x: {item['reason']}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "plan", "publish"))
    args = parser.parse_args()
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        os.environ["GH_TOKEN"] = token
    api = GitHub(os.environ.get("GITHUB_REPOSITORY", "hellomrli/my-nvidia-vgpu-driver"), token)
    out = ROOT / "out"
    plan_file = out / "build-plan.json"
    if args.command == "publish":
        publish(json.loads(plan_file.read_text()), api, out)
        return
    resolved = targets.resolve()
    if args.command == "check":
        lines = resolve_lines(os.environ.get("VGPU_MAJORS", "16 19").split())
        result = check_updates(resolved, lines, api)
        summary(resolved, result)
        print(json.dumps(result, indent=2))
        return
    version = require(os.environ["VERSION"], VERSION, "driver version")
    windows = require(os.environ["ALIST_WINVER"], VERSION, "Windows driver version")
    package_dir = os.environ.get("ALIST_PKG_DIR") or f"NVIDIA-GRID-Linux-KVM-{version}-{windows}"
    line = driver_line(os.environ["ALIST_VGPU_BRANCH"], package_dir)
    if line["driver_version"] != version or line["windows_version"] != windows:
        raise ValueError("Manual version inputs do not match the NVIDIA package directory")
    force = os.environ.get("FORCE_REBUILD", "false")
    if force not in ("true", "false"):
        raise ValueError("Invalid FORCE_REBUILD")
    plan = plan_build(resolved, line, os.environ.get("KERNEL_RELEASE", "latest"), api,
                      force=force == "true", requested=os.environ.get("PACKAGE_BUILD_INPUT", "auto"))
    out.mkdir(exist_ok=True)
    plan_file.write_text(json.dumps(plan, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.write(f"build={str(plan['build']).lower()}\nkernel_release={plan['kernel_release']}\n")
            file.write(f"package_build={plan.get('package_build', '')}\n")
    summary(resolved)
    print(json.dumps(plan, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError) as error:
        sys.exit(f"ERROR: {error}")
