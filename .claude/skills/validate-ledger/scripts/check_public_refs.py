#!/usr/bin/env python3
"""Test every ledger `publicRefs` pointer against the carrier it points at.

`publicRefs` is the ledger's own invitation to cross-check an address against a
public publication. That invitation is only worth something if the carrier still
names the address, so this script fetches each cited document and looks for the
deployment's address in it.

What a hit establishes is narrow and worth stating plainly in any report built on
this output: the carrier, as fetched now, names this address. It does not
establish that the address is correct, current, DAO-approved, or that the
document is about the same contract role the ledger assigns it. To keep that
judgement possible, a hit also captures the wording that surrounds the address in
the carrier, so a reader can see the label the publication actually uses.

Documents are fetched once each and shared across every ref that cites them:
most refs are fragments of the same docs.lido.fi page.

Exit codes: 0 every cited ref resolved and named its address, 3 at least one did
not (absent address, unreachable carrier, or no refs at all recorded), 2
usage/IO problem.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

DEFAULT_REPO_ROOT = Path(__file__).resolve().parents[4]

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_ATTENTION = 3

# A stock urllib UA gets 403s from several docs and forum hosts; a browser-ish
# string is the difference between "carrier unreachable" and a real answer.
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 lido-ledger-validation"
)
TIMEOUT_SECONDS = 30
RETRIES = 2
POLITE_DELAY_SECONDS = 0.5
LABEL_CONTEXT_CHARS = 140

ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}")
HEADING_ID_RE = re.compile(r"<h[1-6][^>]*\bid=\"([^\"]+)\"", re.IGNORECASE)
ANY_ID_RE = re.compile(r"\bid=\"([^\"]+)\"")
DISCOURSE_TOPIC_RE = re.compile(
    r"^/t/(?P<slug>[^/]+)/(?P<topic>\d+)(?:/\d+)?/?$"
)


class TextExtractor(HTMLParser):
    """Collect visible text, dropping script/style payloads."""

    _SKIP = {"script", "style", "noscript", "template", "svg"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs: Any) -> None:
        if tag in self._SKIP:
            self._skip_depth += 1
        self.parts.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag in self._SKIP and self._skip_depth:
            self._skip_depth -= 1
        self.parts.append(" ")

    def handle_data(self, data: str) -> None:
        if not self._skip_depth:
            self.parts.append(data)

    def text(self) -> str:
        return re.sub(r"[ \t\r\f\v]+", " ", "".join(self.parts))


def html_to_text(markup: str) -> str:
    extractor = TextExtractor()
    try:
        extractor.feed(markup)
        extractor.close()
    except Exception:  # noqa: BLE001 - malformed markup must not abort the run
        return re.sub(r"\s+", " ", unescape(re.sub(r"<[^>]+>", " ", markup)))
    return extractor.text()


def fetch(url: str) -> tuple[int | None, str, str | None]:
    """Return (status, body, error). Retries transient failures only."""
    last_error: str | None = None
    for attempt in range(RETRIES + 1):
        request = urllib.request.Request(  # noqa: S310 - http(s) enforced by caller
            url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"}
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                charset = response.headers.get_content_charset() or "utf-8"
                return response.status, response.read().decode(charset, "replace"), None
        except urllib.error.HTTPError as exc:
            body = ""
            try:
                body = exc.read().decode("utf-8", "replace")
            except Exception:  # noqa: BLE001
                pass
            # 4xx is the carrier's answer, not a glitch: do not retry it.
            if exc.code < 500:
                return exc.code, body, f"HTTP {exc.code} {exc.reason}"
            last_error = f"HTTP {exc.code} {exc.reason}"
        except Exception as exc:  # noqa: BLE001 - urllib raises a wide family
            last_error = f"{type(exc).__name__}: {exc}"
        if attempt < RETRIES:
            time.sleep(POLITE_DELAY_SECONDS * (attempt + 2))
    return None, "", last_error


def fetch_discourse_topic(base: str, path_match: re.Match[str]) -> dict[str, Any]:
    """Fetch a Discourse topic through its JSON API, including later pages.

    A forum topic's HTML only carries the posts Discourse chose to render, so an
    address quoted in post 40 of 60 would read as absent from a page fetch.
    """
    origin = f"{urlsplit(base).scheme}://{urlsplit(base).netloc}"
    slug = path_match.group("slug")
    topic = path_match.group("topic")
    status, body, error = fetch(f"{origin}/t/{slug}/{topic}.json")
    if error or not body:
        return {"ok": False, "status": status, "error": error, "via": "discourse-json"}
    try:
        data = json.loads(body)
    except ValueError as exc:
        return {
            "ok": False,
            "status": status,
            "error": f"invalid JSON: {exc}",
            "via": "discourse-json",
        }

    stream = (data.get("post_stream") or {}).get("stream") or []
    posts = list((data.get("post_stream") or {}).get("posts") or [])
    have = {post.get("id") for post in posts}
    missing = [pid for pid in stream if pid not in have]
    pages = 1
    while missing:
        chunk, missing = missing[:50], missing[50:]
        query = "&".join(f"post_ids[]={pid}" for pid in chunk)
        time.sleep(POLITE_DELAY_SECONDS)
        _, more_body, more_error = fetch(f"{origin}/t/{topic}/posts.json?{query}")
        pages += 1
        if more_error or not more_body:
            break
        try:
            more = json.loads(more_body)
        except ValueError:
            break
        posts.extend((more.get("post_stream") or {}).get("posts") or [])

    markup = "\n".join(str(post.get("cooked") or "") for post in posts)
    return {
        "ok": True,
        "status": status,
        "error": None,
        "via": "discourse-json",
        "markup": markup,
        "title": data.get("title"),
        "note": f"{len(posts)} of {len(stream)} posts across {pages} API page(s)",
    }


def load_carrier(url: str) -> dict[str, Any]:
    """Fetch one document and pre-compute everything the ref checks need."""
    split = urlsplit(url)
    record: dict[str, Any] = {
        "url": url,
        "fetchedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "via": "html",
        "httpStatus": None,
        "error": None,
        "bytes": 0,
        "addressCount": 0,
        "anchorIds": [],
        "note": None,
        "title": None,
    }
    if split.scheme not in {"http", "https"}:
        record["error"] = f"unsupported URL scheme {split.scheme!r}"
        return record

    topic = DISCOURSE_TOPIC_RE.match(split.path)
    markup: str | None = None
    if topic:
        # A /t/<slug>/<id> path is the Discourse shape. Try the JSON API, but a
        # host that merely looks like a forum must still be checked, so fall
        # back to the plain page rather than reporting it unreachable.
        result = fetch_discourse_topic(url, topic)
        if result["ok"]:
            record["via"] = result["via"]
            record["httpStatus"] = result.get("status")
            record["note"] = result["note"]
            record["title"] = result["title"]
            markup = result["markup"]
        else:
            record["note"] = f"discourse API unavailable ({result['error']}); read the page instead"

    if markup is None:
        status, body, error = fetch(url)
        record["httpStatus"] = status
        if error:
            record["error"] = error
            return record
        markup = body

    text = html_to_text(markup)
    record["bytes"] = len(markup)
    record["_markup"] = markup
    record["_text"] = text
    record["_markupLower"] = markup.lower()
    record["_textLower"] = text.lower()
    record["addressCount"] = len({m.group(0).lower() for m in ADDRESS_RE.finditer(text)})
    # Heading anchors first (the kind a #fragment in the ledger targets), then
    # any other id, so an anchor moved onto a wrapper element still resolves.
    record["anchorIds"] = sorted(
        set(HEADING_ID_RE.findall(markup)) | set(ANY_ID_RE.findall(markup))
    )
    return record


def label_context(text: str, text_lower: str, address: str) -> str | None:
    """Return the carrier's own wording around the address occurrence."""
    index = text_lower.find(address.lower())
    if index == -1:
        return None
    start = max(0, index - LABEL_CONTEXT_CHARS)
    snippet = text[start : index + len(address) + 40]
    return re.sub(r"\s+", " ", snippet).strip()


def check_refs(ledger: dict[str, Any], carriers: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []
    for entry in ledger["deployments"]:
        for ref in entry.get("publicRefs") or []:
            split = urlsplit(ref)
            document = urlunsplit((split.scheme, split.netloc, split.path, split.query, ""))
            carrier = carriers[document]
            address = entry["address"]
            check: dict[str, Any] = {
                "deploymentId": entry["deploymentId"],
                "contractId": entry["contractId"],
                "contractName": entry["contractName"],
                "networkId": entry["networkId"],
                "address": address,
                "ref": ref,
                "carrier": document,
                "fragment": split.fragment or None,
                "verdict": None,
                "occurrence": None,
                "fragmentResolves": None,
                "labelContext": None,
            }
            if carrier.get("error"):
                check["verdict"] = "carrier-unreachable"
                check["detail"] = carrier["error"]
                checks.append(check)
                continue

            lowered = address.lower()
            in_text = lowered in carrier["_textLower"]
            in_markup = lowered in carrier["_markupLower"]
            if in_text:
                check["verdict"] = "address-present"
                check["occurrence"] = "visible-text"
                check["labelContext"] = label_context(
                    carrier["_text"], carrier["_textLower"], address
                )
            elif in_markup:
                # Only inside an attribute (a link target, say). Still a real
                # occurrence, but not something a reader of the page can see.
                check["verdict"] = "address-present"
                check["occurrence"] = "markup-only"
            else:
                check["verdict"] = "address-absent"
                check["occurrence"] = None

            if split.fragment:
                check["fragmentResolves"] = split.fragment in carrier["anchorIds"]
            checks.append(check)
    return checks


def collect_gaps(ledger: dict[str, Any], checks: list[dict[str, Any]]) -> dict[str, list[Any]]:
    """List the evidence gaps a report must warn about.

    Absence of a pointer is not evidence that no publication or audit exists;
    it is evidence that this snapshot offers a reader no way to cross-check.
    """
    unverifiable: dict[str, list[str]] = {}
    for check in checks:
        if check["verdict"] != "address-present":
            unverifiable.setdefault(check["deploymentId"], []).append(
                f"{check['ref']} → {check['verdict']}"
            )

    gaps: dict[str, list[Any]] = {
        "noPublicRefs": [],
        "sourceNull": [],
        "sourceWithoutCommit": [],
        "noAuditReportRefs": [],
        "publicRefUnverifiable": [
            {"deploymentId": did, "refs": refs} for did, refs in sorted(unverifiable.items())
        ],
        # Deliberately not called "no evidence at all": this workflow reads
        # publicRefs and source only. An entry here may still carry
        # auditReportRefs, which nothing in this run fetches or tests, so the
        # count travels with the finding to keep the label honest.
        "noPublicRefsAndNoSource": [],
    }
    for entry in ledger["deployments"]:
        deployment_id = entry["deploymentId"]
        source = entry.get("source")
        has_refs = bool(entry.get("publicRefs"))
        has_source = isinstance(source, dict) and bool(source.get("repositoryUrl"))
        if not has_refs:
            gaps["noPublicRefs"].append(deployment_id)
        if not has_source:
            gaps["sourceNull"].append(deployment_id)
        elif not source.get("commit"):
            gaps["sourceWithoutCommit"].append(deployment_id)
        if not entry.get("auditReportRefs"):
            gaps["noAuditReportRefs"].append(deployment_id)
        # The sharpest gap this run can see: no way to cross-check the
        # address, and no way to check its source.
        if not has_refs and not has_source:
            gaps["noPublicRefsAndNoSource"].append(
                {
                    "deploymentId": deployment_id,
                    "auditReportRefs": len(entry.get("auditReportRefs") or []),
                }
            )
    return gaps


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    parser.add_argument("--ledger", type=Path, default=None)
    parser.add_argument(
        "--out", type=Path, default=None, help="Write the JSON evidence artifact here"
    )
    parser.add_argument(
        "--carrier-dir",
        type=Path,
        default=None,
        help="Save each fetched carrier for replay (default: skip saving)",
    )
    parser.add_argument(
        "--offline-dir",
        type=Path,
        default=None,
        help="Read carriers from a previous --carrier-dir instead of the network",
    )
    return parser


def sha256_file(path: Path) -> str | None:
    """Hash one file so a report can name the method edition that produced it."""
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def carrier_failure_clusters(carriers: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Group unreachable carriers by what refused, without judging the group.

    Treating N unreachable carriers as N findings is right when N hosts each had
    their own problem, and wrong when one dropped uplink, one proxy or one
    blocked User-Agent produced all of them. The grouping and the share it
    covers are published here; whether a cluster is one common-mode finding is
    the report's judgement.
    """
    clusters: dict[tuple[Any, ...], dict[str, Any]] = {}
    for url, carrier in carriers.items():
        if not carrier.get("error"):
            continue
        host = (urlsplit(url).hostname or "").lower() or None
        error = carrier["error"]
        # Keep the class, drop the instance detail, so one cause groups.
        error_class = error.split(":")[0].strip() if ":" in error else error
        key = (host, carrier.get("httpStatus"), error_class)
        cluster = clusters.setdefault(
            key,
            {
                "host": host,
                "httpStatus": carrier.get("httpStatus"),
                "errorClass": error_class,
                "carriers": [],
            },
        )
        cluster["carriers"].append(url)
    return [
        {
            **cluster,
            "carriers": sorted(cluster["carriers"]),
            "carrierCount": len(cluster["carriers"]),
            "carriersTotal": len(carriers),
        }
        for cluster in sorted(
            clusters.values(), key=lambda c: (-len(c["carriers"]), str(c["host"]))
        )
    ]


def carrier_filename(url: str) -> str:
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]
    slug = re.sub(r"[^a-z0-9]+", "-", url.lower())[:80].strip("-")
    return f"{slug}-{digest}"


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    repo_root = args.repo_root.resolve()
    ledger_path = (args.ledger or repo_root / "ledger" / "ledger.json").resolve()
    if not ledger_path.is_file():
        print(f"Ledger not found: {ledger_path}", file=sys.stderr)
        return EXIT_USAGE

    ledger = json.loads(ledger_path.read_text(encoding="utf-8"))

    documents: dict[str, list[str]] = {}
    for entry in ledger["deployments"]:
        for ref in entry.get("publicRefs") or []:
            split = urlsplit(ref)
            document = urlunsplit((split.scheme, split.netloc, split.path, split.query, ""))
            documents.setdefault(document, []).append(ref)

    carriers: dict[str, dict[str, Any]] = {}
    for index, document in enumerate(sorted(documents)):
        if args.offline_dir:
            saved = args.offline_dir / f"{carrier_filename(document)}.html"
            if not saved.is_file():
                carriers[document] = {
                    "url": document,
                    "error": f"no saved carrier at {saved}",
                    "via": "offline",
                    "fetchedAt": None,
                    "httpStatus": None,
                    "bytes": 0,
                    "addressCount": 0,
                    "anchorIds": [],
                    "note": None,
                    "title": None,
                }
                continue
            markup = saved.read_text(encoding="utf-8", errors="replace")
            text = html_to_text(markup)
            carriers[document] = {
                "url": document,
                "fetchedAt": datetime.fromtimestamp(
                    saved.stat().st_mtime, tz=timezone.utc
                ).isoformat(timespec="seconds"),
                "via": "offline",
                "httpStatus": None,
                "error": None,
                "bytes": len(markup),
                "note": f"read from {saved}",
                "title": None,
                "_markup": markup,
                "_text": text,
                "_markupLower": markup.lower(),
                "_textLower": text.lower(),
                "addressCount": len(
                    {m.group(0).lower() for m in ADDRESS_RE.finditer(text)}
                ),
                "anchorIds": sorted(
                    set(HEADING_ID_RE.findall(markup)) | set(ANY_ID_RE.findall(markup))
                ),
            }
        else:
            if index:
                time.sleep(POLITE_DELAY_SECONDS)
            carriers[document] = load_carrier(document)
            print(
                f"  fetched {document} "
                f"({carriers[document].get('error') or str(carriers[document]['bytes']) + ' bytes'})",
                file=sys.stderr,
            )
            if args.carrier_dir and carriers[document].get("_markup"):
                args.carrier_dir.mkdir(parents=True, exist_ok=True)
                (args.carrier_dir / f"{carrier_filename(document)}.html").write_text(
                    carriers[document]["_markup"], encoding="utf-8"
                )

    checks = check_refs(ledger, carriers)
    gaps = collect_gaps(ledger, checks)

    by_verdict: dict[str, int] = {}
    for check in checks:
        by_verdict[check["verdict"]] = by_verdict.get(check["verdict"], 0) + 1

    report = {
        "kind": "public-refs-check",
        "checkedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        # Which edition of this checker produced the verdicts below, and which
        # snapshot it read. Reports are meant to be diffed against each other,
        # and two verdicts are only comparable when both are the same.
        "method": {
            "checker": Path(__file__).name,
            "checkerSha256": sha256_file(Path(__file__).resolve()),
            "mode": "offline" if args.offline_dir else "network",
        },
        "ledger": str(ledger_path.relative_to(repo_root)),
        "ledgerSha256": sha256_file(ledger_path),
        "ledgerUpdatedAt": ledger.get("updatedAt"),
        "establishes": (
            "the fetched carrier names this address; not that the address is "
            "correct, current, approved, or plays the role the ledger assigns it"
        ),
        "totals": {
            "deployments": len(ledger["deployments"]),
            "deploymentsWithRefs": sum(
                1 for e in ledger["deployments"] if e.get("publicRefs")
            ),
            "refCitations": len(checks),
            "distinctCarriers": len(carriers),
            "byVerdict": by_verdict,
            "fragmentsUnresolved": sum(
                1 for c in checks if c["fragmentResolves"] is False
            ),
        },
        "carrierFailureClusters": carrier_failure_clusters(carriers),
        "carriers": [
            {k: v for k, v in carrier.items() if not k.startswith("_")}
            | {"anchorIds": len(carrier.get("anchorIds") or [])}
            for _, carrier in sorted(carriers.items())
        ],
        "gaps": gaps,
        "checks": checks,
    }

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {args.out}")

    totals = report["totals"]
    print("Public reference claim check")
    print(f"  deployments:            {totals['deployments']}")
    print(f"  with publicRefs:        {totals['deploymentsWithRefs']}")
    print(f"  ref citations checked:  {totals['refCitations']}")
    print(f"  distinct carriers:      {totals['distinctCarriers']}")
    for verdict, count in sorted(by_verdict.items(), key=lambda i: (-i[1], i[0])):
        print(f"  {verdict:<24}{count}")
    print(f"  unresolved #fragments:  {totals['fragmentsUnresolved']}")
    for cluster in report["carrierFailureClusters"]:
        print(
            f"  unreachable cluster:    {cluster['carrierCount']}/"
            f"{cluster['carriersTotal']} carriers "
            f"[{cluster['host']} {cluster['httpStatus'] or '-'} "
            f"{cluster['errorClass']}]"
        )
    print("  gaps:")
    for name, values in gaps.items():
        print(f"    {name:<26}{len(values)}")
    for check in checks:
        if check["verdict"] != "address-present":
            print(
                f"  ! {check['deploymentId']} {check['verdict']}: {check['ref']}"
            )

    needs_attention = any(c["verdict"] != "address-present" for c in checks) or bool(
        gaps["noPublicRefs"]
    )
    return EXIT_ATTENTION if needs_attention else EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
