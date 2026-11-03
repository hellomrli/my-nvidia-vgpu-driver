#!/usr/bin/env python3
"""Resolve current Unraid channels plus ich777's latest preparation kernel."""

from html.parser import HTMLParser
import json
import os
import re
import sys
from urllib.parse import urlparse
from urllib.request import Request, urlopen


# This is the catalog used by the official download_list page's VersionsTable.
CATALOG_URL = "https://releases.unraid.net/json?includePublic=1"
ICH777_URL = "https://api.github.com/repos/ich777/unraid_kernel/releases/latest"
VERSION = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)(?:-(beta|rc)\.?([0-9]+))?")
STATUSES = {"supported", "security-updates", "superseded", "eol"}


def version_key(version):
    match = VERSION.fullmatch(version) if isinstance(version, str) else None
    if not match:
        raise ValueError(f"Unrecognized public Unraid version: {version!r}")
    major, minor, patch, stage, number = match.groups()
    return (int(major), int(minor), int(patch), {"beta": 0, "rc": 1, None: 2}[stage], int(number or 0))


def current_releases(catalog):
    if not isinstance(catalog, list) or not catalog:
        raise ValueError("Missing official Unraid release catalog")
    eligible = {}
    for release in catalog:
        if not isinstance(release, dict) or type(release.get("public")) is not bool:
            raise ValueError("Invalid Unraid catalog entry")
        if not release["public"]:
            continue
        key = version_key(release.get("version"))
        status = release.get("supportStatus")
        if status not in STATUSES:
            raise ValueError("Missing/unknown release support status; refusing stale fallback")
        if status not in ("supported", "security-updates"):
            continue
        if key in eligible:
            raise ValueError("Duplicate public release version")
        eligible[key] = release
    stable_keys = [key for key in eligible if key[3] == 2]
    if not stable_keys:
        raise ValueError("No current public stable release in official catalog")
    stable = max(stable_keys)
    # Old RCs must not survive promotion to stable or keep old kernels alive.
    next_keys = [key for key in eligible if key[3] < 2 and key > stable]
    return {"stable": eligible[stable], "next": eligible[max(next_keys)] if next_keys else None}


class ReleaseNotes(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_main = False
        self.in_h1 = False
        self.titles = []
        self.title = []
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag == "main":
            self.in_main = True
        if self.in_main and tag == "h1":
            self.in_h1 = True
            self.title = []
        if self.in_main and tag in ("p", "li", "h1", "h2", "h3", "h4"):
            self.text.append("\n")

    def handle_endtag(self, tag):
        if tag == "h1" and self.in_h1:
            self.titles.append("".join(self.title).strip())
            self.in_h1 = False
        if tag == "main":
            self.in_main = False
        if self.in_main and tag in ("p", "li", "h1", "h2", "h3", "h4"):
            self.text.append("\n")

    def handle_data(self, data):
        if self.in_main:
            self.text.append(data)
        if self.in_h1:
            self.title.append(data)


def kernel_from_notes(html, version):
    page = ReleaseNotes()
    page.feed(html)
    if len(page.titles) != 1 or not re.match(r"^Version\s+" + re.escape(version) + r"(?:\s|$)", page.titles[0]):
        raise ValueError(f"Release notes do not describe catalog version {version}")
    text = "".join(page.text)
    kernels = set(re.findall(
        r"(?i)Linux kernel\s*:\s*(?:(?:update to|version)\s*:?\s*)?"
        r"([0-9]+\.[0-9]+\.[0-9]+)(?:-Unraid)?\b", text))
    if len(kernels) != 1:
        raise ValueError(f"Missing/ambiguous Linux kernel in {version} release notes")
    return kernels.pop() + "-Unraid"


def fetch(url):
    headers = {"User-Agent": "my-nvidia-vgpu-driver/kernel-resolver"}
    if urlparse(url).hostname == "api.github.com" and os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    request = Request(url, headers=headers)
    with urlopen(request, timeout=45) as response:
        if urlparse(response.url).hostname != urlparse(url).hostname:
            raise ValueError("Unexpected cross-host redirect from official release metadata")
        data = response.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError("Official release response is unexpectedly large")
        return data.decode("utf-8")


def resolve(fetch_text=fetch):
    releases = current_releases(json.loads(fetch_text(CATALOG_URL)))
    result = {}
    for channel, release in releases.items():
        if release is None:
            result[channel] = None
            continue
        url = release.get("changelog_pretty", "")
        if not isinstance(url, str) or not re.fullmatch(
                r"https://docs\.unraid\.net/unraid-os/release-notes/[0-9A-Za-z.-]+/", url):
            raise ValueError("Release catalog lacks an official release-notes URL")
        result[channel] = {"version": release["version"], "release_notes": url,
                           "kernel_release": kernel_from_notes(fetch_text(url), release["version"])}
    archive = json.loads(fetch_text(ICH777_URL))
    kernel = archive.get("tag_name") if isinstance(archive, dict) else None
    if not isinstance(kernel, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-Unraid", kernel):
        raise ValueError("Invalid ich777 latest kernel release")
    if archive.get("draft") is not False or not isinstance(archive.get("assets"), list) or not any(
            isinstance(asset, dict) and
            asset.get("name") == f"linux-{kernel}.tar.xz" and asset.get("state") == "uploaded"
            and type(asset.get("size")) is int and asset["size"] > 0 for asset in archive["assets"]):
        raise ValueError("ich777 latest release has no complete kernel source archive")
    result["ich777"] = {"kernel_release": kernel,
                         "release_url": f"https://github.com/ich777/unraid_kernel/releases/tag/{kernel}"}
    result["kernel_releases"] = sorted({r["kernel_release"] for r in result.values() if r})
    return result


def main():
    result = resolve()
    print(json.dumps(result, indent=2))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("kernel_releases=" + json.dumps(result["kernel_releases"]) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write("### Current Unraid build targets\n\n")
            for channel in ("stable", "next"):
                release = result[channel]
                output.write(f"- {channel}: " + (f"[{release['version']}]({release['release_notes']})"
                             f" / `{release['kernel_release']}`" if release else "no current public prerelease") + "\n")
            archive = result["ich777"]
            output.write(f"- ich777 preparation: [{archive['kernel_release']}]({archive['release_url']})\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(f"ERROR: {error}")
