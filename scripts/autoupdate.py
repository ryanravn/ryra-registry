#!/usr/bin/env python3
"""Registry autoupdate bot.

Reads each recipe's [autoupdate] hint (see ryra-core's AutoupdateHint),
discovers the newest upstream version, and rewrites the version
substring in the recipe's quadlet Image= lines when upstream is newer.

Philosophy: the box never self-updates app versions. This script only
prepares version-bump commits in the registry; the VM test CI gates the
merge, and users upgrade explicitly.

Usage:
    scripts/autoupdate.py [--dry-run | --apply] [service ...]

Default is a dry run: planned bumps are printed, nothing changes.
With --apply the quadlet files are rewritten in place. Passing one or
more service names restricts the run to those recipes.

Machine-readable output (consumed by the autoupdate workflow):
    BUMP <service> <old> <new>     a newer upstream version was found
    OK <service> <version>         already current
    HOLD <service> <old> <new>     upstream is older than the pin
                                   (never downgrade)
Warnings and errors go to stderr as "WARNING: <service>: ..." and the
exit code is 1 when any recipe with a hint could not be checked; no
hint is ever skipped silently.

Stdlib only: urllib, json, re, tomllib.
"""

import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request

REGISTRY_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTTP_TIMEOUT = 30
MAX_TAG_PAGES = 20
USER_AGENT = "ryra-registry-autoupdate/1 (+https://ryra.app)"

# docker.io is an alias; the actual v2 API host differs.
REGISTRY_API_HOSTS = {"docker.io": "registry-1.docker.io"}


class HintError(Exception):
    """A recipe's hint could not be resolved; message names the cause."""


def http_get(url, headers=None):
    """GET url, return (status, headers, body bytes). Raises on network
    errors; HTTP error statuses are returned, not raised."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()


def version_key(version):
    """Numeric tuple for a version string: split on dots and hyphens,
    take the leading digit run of each part. 'v2.7.4' -> (2, 7, 4),
    '7.0.1-0019' -> (7, 0, 1, 19). Never a plain string compare."""
    parts = []
    for part in re.split(r"[.\-]", version):
        m = re.search(r"\d+", part)
        parts.append(int(m.group(0)) if m else -1)
    return tuple(parts)


def shape_regex(version):
    """A regex matching strings of the same shape as `version`, with
    every digit run generalized: 'v2.7.4' -> r'v\\d+\\.\\d+\\.\\d+'."""
    return re.sub(r"\d+", r"\\d+", re.escape(version))


def parse_image_ref(ref):
    """Split an Image= value into (host, repo, tag). Digest-pinned refs
    (@sha256:...) and untagged refs return tag=None."""
    if "@" in ref:
        name = ref.split("@", 1)[0]
        tag = None
    else:
        slash = ref.rfind("/")
        colon = ref.rfind(":")
        if colon > slash:
            name, tag = ref[:colon], ref[colon + 1 :]
        else:
            name, tag = ref, None
    first, _, rest = name.partition("/")
    if "." in first or ":" in first:
        host, repo = first, rest
    else:
        host, repo = "docker.io", name
    return host, repo, tag


def load_recipes(only):
    """Yield (service, hint dict or None, quadlet dir). Errors loudly on
    unknown service names passed on the command line."""
    names = sorted(
        d
        for d in os.listdir(REGISTRY_ROOT)
        if os.path.isfile(os.path.join(REGISTRY_ROOT, d, "service.toml"))
    )
    if only:
        unknown = [s for s in only if s not in names]
        if unknown:
            sys.exit(f"ERROR: no such recipe: {', '.join(unknown)}")
        names = [n for n in names if n in only]
    for name in names:
        with open(os.path.join(REGISTRY_ROOT, name, "service.toml"), "rb") as f:
            doc = tomllib.load(f)
        yield name, doc.get("autoupdate"), os.path.join(REGISTRY_ROOT, name, "quadlets")


def read_images(quadlet_dir):
    """All Image= refs across the recipe's .container files, in order,
    as (file path, ref) pairs."""
    images = []
    if not os.path.isdir(quadlet_dir):
        return images
    for fname in sorted(os.listdir(quadlet_dir)):
        if not fname.endswith(".container"):
            continue
        path = os.path.join(quadlet_dir, fname)
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("Image="):
                    images.append((path, line[len("Image=") :].strip()))
    return images


def primary_images(service, images):
    """The image(s) the version hint is about: refs whose repo path
    contains the service name. Falls back to the only distinct image
    when the recipe has exactly one."""
    primaries = []
    for path, ref in images:
        host, repo, tag = parse_image_ref(ref)
        if tag is None:
            continue
        if service in repo:
            primaries.append((host, repo, tag))
    if not primaries:
        distinct = {(parse_image_ref(ref)) for _, ref in images}
        distinct = {t for t in distinct if t[2] is not None}
        if len(distinct) == 1:
            primaries = list(distinct)
    if not primaries:
        raise HintError("could not identify the primary image for this recipe")
    return primaries


def github_latest(repo, tag_regex, token):
    """Newest non-draft, non-prerelease release version of a GitHub
    repo. tag_regex's first capture group (when set) is the version;
    without a regex the whole tag is."""
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    status, _, body = http_get(url, headers)
    if status != 200:
        raise HintError(f"GitHub releases API returned HTTP {status} for {repo}")
    versions = []
    for release in json.loads(body):
        if release.get("draft") or release.get("prerelease"):
            continue
        tag = release.get("tag_name", "")
        if tag_regex:
            m = re.fullmatch(tag_regex, tag)
            if not m:
                continue
            versions.append(m.group(1) if m.groups() else m.group(0))
        else:
            versions.append(tag)
    if not versions:
        raise HintError(f"no GitHub release of {repo} matched tag_regex {tag_regex!r}")
    return max(versions, key=version_key)


def registry_token(www_authenticate, repo):
    """Fetch an anonymous bearer token as directed by a 401's
    WWW-Authenticate header (docker.io, ghcr.io, quay.io, lscr.io all
    speak this flow)."""
    m = re.match(r'Bearer\s+(.*)', www_authenticate or "")
    if not m:
        raise HintError(f"unsupported auth challenge: {www_authenticate!r}")
    fields = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
    realm = fields.get("realm")
    if not realm:
        raise HintError(f"auth challenge without realm: {www_authenticate!r}")
    params = {k: v for k, v in fields.items() if k not in ("realm",)}
    params.setdefault("scope", f"repository:{repo}:pull")
    status, _, body = http_get(f"{realm}?{urllib.parse.urlencode(params)}")
    if status != 200:
        raise HintError(f"token endpoint {realm} returned HTTP {status}")
    doc = json.loads(body)
    token = doc.get("token") or doc.get("access_token")
    if not token:
        raise HintError(f"token endpoint {realm} returned no token")
    return token


def registry_tags(host, repo):
    """All tags of an image via the registry v2 tags API, following
    pagination up to MAX_TAG_PAGES."""
    api_host = REGISTRY_API_HOSTS.get(host, host)
    url = f"https://{api_host}/v2/{repo}/tags/list?n=1000"
    headers = {}
    tags = []
    for _ in range(MAX_TAG_PAGES):
        status, resp_headers, body = http_get(url, headers)
        if status == 401 and "Authorization" not in headers:
            token = registry_token(resp_headers.get("www-authenticate", ""), repo)
            headers["Authorization"] = f"Bearer {token}"
            continue
        if status != 200:
            raise HintError(f"tags API for {host}/{repo} returned HTTP {status}")
        tags.extend(json.loads(body).get("tags") or [])
        link = resp_headers.get("link", "")
        m = re.search(r'<([^>]+)>;\s*rel="next"', link)
        if not m:
            break
        url = urllib.parse.urljoin(url, m.group(1))
    else:
        raise HintError(f"tags API for {host}/{repo}: gave up after {MAX_TAG_PAGES} pages")
    if not tags:
        raise HintError(f"tags API for {host}/{repo} returned no tags")
    return tags


def registry_latest(host, repo, tag_regex):
    """Newest image tag version matching tag_regex (first capture group,
    or the whole tag when the regex has no group)."""
    versions = []
    for tag in registry_tags(host, repo):
        if tag_regex:
            m = re.fullmatch(tag_regex, tag)
            if not m:
                continue
            versions.append(m.group(1) if m.groups() else m.group(0))
        else:
            versions.append(tag)
    if not versions:
        raise HintError(f"no tag of {host}/{repo} matched tag_regex {tag_regex!r}")
    return max(versions, key=version_key)


def current_version(service, primaries, new_version):
    """The version currently pinned in the quadlets: the substring of
    the primary image tag(s) with the same shape as new_version. All
    primaries must agree."""
    shape = shape_regex(new_version)
    found = set()
    for host, repo, tag in primaries:
        m = re.fullmatch(shape, tag) or re.search(shape, tag)
        if m:
            found.add(m.group(0))
    if not found:
        raise HintError(
            f"discovered version {new_version!r} has no counterpart in the "
            f"pinned tags {sorted(t for _, _, t in primaries)!r}: "
            "check tag_regex against the quadlet tag format"
        )
    if len(found) > 1:
        raise HintError(f"primary images disagree on the pinned version: {sorted(found)!r}")
    return found.pop()


def rewrite_quadlets(quadlet_dir, old, new, apply_changes):
    """Replace `old` with `new` in the tag of every Image= line that
    carries it (bounded so '1' never matches inside '13'). Returns the
    list of files that changed (or would change)."""
    bounded = re.compile(rf"(?<![\w.]){re.escape(old)}(?![\w.])")
    changed = []
    for fname in sorted(os.listdir(quadlet_dir)):
        if not fname.endswith(".container"):
            continue
        path = os.path.join(quadlet_dir, fname)
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
        touched = False
        for i, line in enumerate(lines):
            if not line.startswith("Image=") or "@" in line:
                continue
            ref = line[len("Image=") :].rstrip("\n")
            colon = ref.rfind(":")
            if colon <= ref.rfind("/"):
                continue
            name, tag = ref[:colon], ref[colon + 1 :]
            new_tag = bounded.sub(new, tag)
            if new_tag != tag:
                lines[i] = f"Image={name}:{new_tag}\n"
                touched = True
        if touched:
            changed.append(path)
            if apply_changes:
                with open(path, "w", encoding="utf-8") as f:
                    f.writelines(lines)
    if not changed:
        raise HintError(f"planned bump {old} -> {new} but no Image= line carries {old!r}")
    return changed


def process(service, hint, quadlet_dir, apply_changes, token):
    strategy = hint.get("strategy")
    tag_regex = hint.get("tag_regex")
    images = read_images(quadlet_dir)
    if not images:
        raise HintError("recipe has an [autoupdate] hint but no quadlet Image= lines")
    primaries = primary_images(service, images)

    if strategy == "github-release":
        repo = hint.get("repo")
        if not repo:
            raise HintError("github-release hint is missing repo")
        newest = github_latest(repo, tag_regex, token)
    elif strategy == "registry-tags":
        hosts = {(h, r) for h, r, _ in primaries}
        if len(hosts) > 1:
            raise HintError(f"registry-tags hint is ambiguous across images: {sorted(hosts)!r}")
        host, repo = hosts.pop()
        newest = registry_latest(host, repo, tag_regex)
    else:
        raise HintError(f"unknown autoupdate strategy {strategy!r}")

    if strategy == "registry-tags" and tag_regex:
        # The pinned tag must itself match the regex; its capture is the
        # current version. (The shape heuristic below would drop a build
        # suffix when the newest upstream version happens to lack one.)
        found = set()
        for _, _, tag in primaries:
            m = re.fullmatch(tag_regex, tag)
            if m:
                found.add(m.group(1) if m.groups() else m.group(0))
        if not found:
            raise HintError(
                f"no primary image tag matches tag_regex {tag_regex!r}: "
                f"pinned tags are {sorted(t for _, _, t in primaries)!r}"
            )
        if len(found) > 1:
            raise HintError(f"primary images disagree on the pinned version: {sorted(found)!r}")
        current = found.pop()
    else:
        current = current_version(service, primaries, newest)
    if version_key(newest) > version_key(current):
        changed = rewrite_quadlets(quadlet_dir, current, newest, apply_changes)
        verb = "bumped" if apply_changes else "would bump"
        print(f"BUMP {service} {current} {newest}")
        for path in changed:
            print(f"    {verb} {os.path.relpath(path, REGISTRY_ROOT)}")
    elif version_key(newest) < version_key(current):
        print(f"HOLD {service} {current} {newest}")
        print(f"    upstream {newest} is older than the pin {current}; never downgrading")
    else:
        print(f"OK {service} {current}")


def main(argv):
    apply_changes = False
    only = []
    for arg in argv:
        if arg == "--apply":
            apply_changes = True
        elif arg == "--dry-run":
            apply_changes = False
        elif arg.startswith("-"):
            sys.exit(f"ERROR: unknown flag {arg!r} (use --dry-run or --apply)")
        else:
            only.append(arg)

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    failures = 0
    hinted = 0
    for service, hint, quadlet_dir in load_recipes(only):
        if hint is None:
            continue
        hinted += 1
        try:
            process(service, hint, quadlet_dir, apply_changes, token)
        except HintError as e:
            failures += 1
            print(f"WARNING: {service}: {e}", file=sys.stderr)
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as e:
            failures += 1
            print(f"WARNING: {service}: upstream query failed: {e}", file=sys.stderr)
    if hinted == 0:
        sys.exit("ERROR: no recipe with an [autoupdate] hint matched")
    if failures:
        print(f"WARNING: {failures} recipe(s) could not be checked", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
