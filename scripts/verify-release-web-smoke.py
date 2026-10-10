#!/usr/bin/env python3
"""Verify the installed release serves its version metadata and linked assets."""

import argparse
from html.parser import HTMLParser
import sys
from urllib.request import urlopen
from urllib.error import URLError
from urllib.parse import urljoin


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack, self.assets, self.text = [], [], {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "link" and "stylesheet" in attrs.get("rel", "").split():
            self.assets.append(("stylesheet", attrs.get("href")))
        if tag == "script" and "src" in attrs:
            self.assets.append(("script", attrs["src"]))
        if tag not in {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}:
            self.stack.append((tag, attrs.get("id")))

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        for _, element_id in self.stack:
            if element_id in {"app-version-trigger", "app-version-tooltip"}:
                self.text[element_id] = self.text.get(element_id, "") + data


def fetch(url):
    try:
        response = urlopen(url, timeout=30)
    except URLError as error:
        raise ValueError(f"{url}: {error}") from error
    with response:
        if response.status != 200:
            raise ValueError(f"{url}: HTTP {response.status}")
        payload = response.read()
        if not payload:
            raise ValueError(f"{url}: empty response")
        return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_url")
    parser.add_argument("version")
    parser.add_argument("source_sha", nargs="?")
    args = parser.parse_args()
    page = Page()
    page.feed(fetch(urljoin(args.base_url.rstrip("/") + "/", "/")).decode("utf-8"))
    label = " ".join(page.text.get("app-version-trigger", "").split())
    if label != f"v{args.version}":
        raise ValueError(f"version badge: expected v{args.version}, got {label!r}")
    details = page.text.get("app-version-tooltip", "").splitlines()
    expected = [f"Git ref: v{args.version}"]
    if args.source_sha:
        expected.append(f"Commit: {args.source_sha}")
    for value in expected:
        if value not in [line.strip() for line in details]:
            raise ValueError(f"version tooltip missing {value!r}")
    if {kind for kind, _ in page.assets} != {"stylesheet", "script"}:
        raise ValueError("page must link stylesheet and script assets")
    for _, path in page.assets:
        if not path:
            raise ValueError("linked asset has no URL")
        fetch(urljoin(args.base_url, path))
    print(f"Release web smoke passed: v{args.version}, {len(page.assets)} assets")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Release web smoke failed: {error}")
