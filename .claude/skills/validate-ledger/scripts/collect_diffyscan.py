#!/usr/bin/env python3
"""Turn a Diffyscan sweep into per-deployment source-provenance outcomes.

`just diffyscan-sources` leaves one stdout log per cohort under
diffyscan/logs/. Those logs answer "did this cohort pass", but a report has to
answer "what is established about this one deployed address", and the two are
not the same question: a cohort log can end in a GitHub 404, an explorer error,
or a real file diff, and only the last of those says anything about the ledger's
source claim. Collapsing them into "failed" would put a false "sources differ"
finding on a Lido deployment.

Cohort membership is rebuilt by importing the renderer's own projection helpers
rather than re-deriving cohort names here, so this script cannot disagree with
the configs that were actually verified.

A crashed cohort is classified from the HTTP status and host of the request
that failed, not from the exception class or a hostname substring: Diffyscan
raises the same `ExplorerError` for a GitHub 404, a GitHub rate limit, and an
explorer refusal, and those mean three different things. The host is compared
against the cohort's own `repositoryUrl` and the network's configured explorer,
so the classification cannot drift from the config that was verified.

Outcomes per deployment:
  source-match             every file identical against the pinned revision
  source-allowed-diff      differences matched a configured allowlist rule
  source-diff              uncovered file differences (the ledger's pin and the
                           explorer-verified source do not agree)
  source-missing-upstream  the source host answered 404 for the pinned
                           repo/commit/path: the tree does not serve the file
  upstream-unavailable     the source host failed for any other reason (rate
                           limit, auth, 5xx, network); nothing was compared and
                           the pin is NOT impeached
  explorer-unavailable     the explorer refused or is incompatible; nothing was
                           compared, so nothing is established either way
  tool-error               Diffyscan crashed for some other reason
  not-run                  cohort projected but no log present
  no-source-claim          the ledger records no source, so no provenance claim
                           exists for this sweep to test
  unpinned-source-claim    a repository is recorded but no commit, so the
                           revision claim this sweep tests is never made
  not-projected            a full source claim exists but no cohort could be
                           built for it (tooling gap)

Exit codes: 0 nothing needs attention, 3 at least one deployment is not in
source-match/source-allowed-diff, 2 usage/IO problem.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

SKILL_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPO_ROOT = Path(__file__).resolve().parents[4]

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_ATTENTION = 3

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}")
COUNT_RE = re.compile(
    r"(Total contracts analyzed|Exact matches|Allowed diffs|Failures|"
    r"Total files with non-zero diffs):\s*(\d+)"
)
FAILED_BULLET_RE = re.compile(
    r"•\s*(?P<name>\S+)\s*\((?P<address>0x[0-9a-fA-F]{40})\):\s*(?P<files>\d+) file"
)
DURATION_RE = re.compile(r"Done in ([0-9.]+)s")

SOURCE_SUMMARY_HEADER = "SOURCE CODE COMPARISON SUMMARY:"
BYTECODE_SUMMARY_HEADER = "BYTECODE COMPARISON SUMMARY:"
UNCOVERED_SOURCE_HEADER = "Contracts with uncovered source code differences:"

# Diffyscan wraps every remote failure in one exception class, so the class name
# settles nothing. The status line it prints does: "HTTP error: 404 Client
# Error: Not Found for url: https://api.github.com/...".
HTTP_ERROR_RE = re.compile(
    r"HTTP error:\s*(?P<status>\d{3})\b.*?for url:\s*(?P<url>https?://\S+)",
    re.IGNORECASE | re.DOTALL,
)
FOR_URL_RE = re.compile(r"for url:\s*(?P<url>https?://\S+)", re.IGNORECASE)
CONN_HOST_RE = re.compile(r"host=['\"](?P<host>[^'\"]+)['\"]")
RATE_LIMIT_RE = re.compile(r"rate limit|API rate limit exceeded", re.IGNORECASE)

# GitHub serves repository contents from hosts that share no registrable suffix
# with the repository URL, so matching the repo host alone would miss them.
UPSTREAM_HOST_ALIASES = {
    "github.com": (
        "api.github.com",
        "raw.githubusercontent.com",
        "codeload.github.com",
    ),
}

# Outcomes that need no follow-up. Everything else is surfaced in the report.
CLEAN_OUTCOMES = frozenset({"source-match", "source-allowed-diff"})

# A crash aborts the whole cohort, so every member is unestablished, not failed.
CRASH_OUTCOMES = frozenset(
    {
        "source-missing-upstream",
        "upstream-unavailable",
        "explorer-unavailable",
        "tool-error",
    }
)

# Blocker keys produced by the renderer, mapped to the outcome they justify and
# the wording that lands in the report verbatim. The split matters: where the
# ledger records no revision, the sweep is not missing evidence for a claim —
# the claim this sweep tests was never made.
OUTSIDE_SWEEP_OUTCOMES = {
    "null_source": (
        "no-source-claim",
        "source is null or has no repositoryUrl — no revision is claimed",
    ),
    "missing_commit": (
        "unpinned-source-claim",
        "source.repositoryUrl present but no source.commit — a repository is "
        "claimed, no revision is",
    ),
    "invalid_source": ("not-projected", "source.repositoryUrl is unusable"),
    "missing_network_meta": (
        "not-projected",
        "networkId missing from diffyscan/networks.json",
    ),
    "missing_profile": (
        "not-projected",
        "no diffyscan/profiles entry for the repository",
    ),
    "unpinned_commit": (
        "not-projected",
        "repository profile has no pin for this commit",
    ),
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=DEFAULT_REPO_ROOT,
        help="Ledger repository root (default: inferred from this script's path)",
    )
    parser.add_argument("--ledger", type=Path, default=None)
    parser.add_argument(
        "--known-blockers",
        type=Path,
        default=SKILL_ROOT / "references" / "known-blockers.json",
        help="Registry of documented sweep blockers and their log signatures",
    )
    parser.add_argument("--logs-dir", type=Path, default=None)
    parser.add_argument("--generated-dir", type=Path, default=None)
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Write the JSON evidence artifact here (default: stdout only)",
    )
    return parser


def load_renderer(repo_root: Path) -> Any:
    """Import the repo's renderer so cohort naming has one definition."""
    scripts_dir = repo_root / "scripts"
    renderer = scripts_dir / "render_diffyscan_config.py"
    if not renderer.is_file():
        raise SystemExit(f"Renderer not found: {renderer}")
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    import render_diffyscan_config as rdc  # noqa: PLC0415  (path set above)

    return rdc


def project_cohorts(rdc: Any, repo_root: Path, ledger_path: Path) -> tuple[
    dict[str, dict[str, Any]],
    dict[str, list[str]],
    dict[str, dict[str, Any]],
]:
    """Rebuild cohort membership exactly as `--from-ledger` would.

    Returns (cohorts_by_id, blockers, deployments_by_id).
    """
    networks_schema = rdc.load_json(repo_root / "diffyscan" / "networks.schema.json")
    profile_schema = rdc.load_json(repo_root / "diffyscan" / "profile.schema.json")
    networks_map = rdc.validate_json_schema(
        rdc.load_json(repo_root / "diffyscan" / "networks.json"),
        networks_schema,
        label="networks map",
    )
    profiles_by_url = rdc.load_profiles(
        repo_root / "diffyscan" / "profiles", profile_schema
    )

    ledger = rdc.load_json(ledger_path)
    deployments_by_id = rdc.index_deployments(ledger)
    grouped, missing_commit, null_source, invalid_source = rdc.classify_deployments(
        deployments_by_id
    )

    cohorts: dict[str, dict[str, Any]] = {}
    blockers: dict[str, list[str]] = {
        "missing_commit": missing_commit,
        "null_source": null_source,
        "invalid_source": invalid_source,
        "missing_network_meta": [],
        "missing_profile": [],
        "unpinned_commit": [],
    }

    for (network_id, repository_url, commit), selected in sorted(grouped.items()):
        deployment_ids = [entry["deploymentId"] for entry in selected]
        try:
            network_slug = rdc.require_network_slug(ledger, network_id)
            rdc.resolve_network_settings(networks_map, network_id)
        except SystemExit:
            blockers["missing_network_meta"].extend(deployment_ids)
            continue
        profile = profiles_by_url.get(repository_url)
        if profile is None:
            blockers["missing_profile"].extend(deployment_ids)
            continue
        if rdc.resolve_profile_settings(profile, commit) is None:
            blockers["unpinned_commit"].extend(deployment_ids)
            continue

        cohort = rdc.cohort_id(profile["profileId"], network_slug, commit)
        cohorts[cohort] = {
            "cohortId": cohort,
            "networkId": network_id,
            "repositoryUrl": repository_url,
            "commit": commit,
            "deploymentIds": deployment_ids,
            # Diffyscan keys results by address, so keep the reverse map to
            # attribute a per-address finding back to one deployment.
            "deploymentIdByAddress": {
                entry["address"].lower(): entry["deploymentId"] for entry in selected
            },
            "contractNameByAddress": {
                entry["address"].lower(): entry["contractName"] for entry in selected
            },
        }

    return cohorts, blockers, deployments_by_id


def upstream_hosts_for(repository_url: str | None) -> set[str]:
    """Hosts that serve the cohort's own pinned repository."""
    host = (urlsplit(repository_url or "").hostname or "").lower()
    if not host:
        return set()
    return {host, *UPSTREAM_HOST_ALIASES.get(host, ())}


def hosts_match(host: str | None, other: str | None) -> bool:
    if not host or not other:
        return False
    host, other = host.lower(), other.lower()
    return host == other or host.endswith("." + other) or other.endswith("." + host)


def failing_endpoint(text: str) -> tuple[int | None, str | None]:
    """Recover the status and host of the last failed request in a log.

    The status is what separates "the pinned tree does not serve this file" from
    "the host would not talk to us", and nothing else in the log does.
    """
    status: int | None = None
    url: str | None = None
    for match in HTTP_ERROR_RE.finditer(text):
        status, url = int(match.group("status")), match.group("url")
    if url is None:
        for match in FOR_URL_RE.finditer(text):
            url = match.group("url")
    if url is not None:
        return status, (urlsplit(url).hostname or "").lower() or None
    conn = None
    for match in CONN_HOST_RE.finditer(text):
        conn = match.group("host")
    return status, conn.lower() if conn else None


def classify_crash(
    text: str,
    repository_url: str | None = None,
    explorer_hostname: str | None = None,
) -> tuple[str, str, dict[str, Any]]:
    """Name the failure class of a crashed run, from the status code it reports.

    A 404 on the pinned tree and a 403 rate limit on the same host mean opposite
    things: the first impeaches the ledger's pin, the second means the check
    never ran. Diffyscan raises one `ExplorerError` for both — and for explorer
    failures too — so the exception class settles nothing and a hostname
    substring settles nothing. The status and host settle it, and both are
    compared against this cohort's own repositoryUrl and configured explorer
    rather than a hardcoded list.
    """
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    error_line = next(
        (
            line
            for line in reversed(lines)
            if re.match(r"^[A-Za-z_][\w.]*(Error|Exception)\b", line)
            or "[ERROR]" in line
        ),
        lines[-1] if lines else "",
    )
    status, host = failing_endpoint(text)
    detail: dict[str, Any] = {
        "httpStatus": status,
        "failingHost": host,
        "hostKind": None,
        "rateLimited": bool(RATE_LIMIT_RE.search(text)),
    }

    if host and host in upstream_hosts_for(repository_url):
        detail["hostKind"] = "upstream"
        if status == 404:
            # Read this together with the run's failure clusters: a lone 404 is
            # a pin problem, while 404 on every cohort of a private or renamed
            # repo is an auth problem wearing a 404.
            return "source-missing-upstream", error_line, detail
        return "upstream-unavailable", error_line, detail
    if hosts_match(host, explorer_hostname):
        detail["hostKind"] = "explorer"
        return "explorer-unavailable", error_line, detail
    if host:
        detail["hostKind"] = "other"
    return "tool-error", error_line, detail


def parse_log(
    path: Path,
    repository_url: str | None = None,
    explorer_hostname: str | None = None,
    blocker_signatures: dict[str, re.Pattern[str]] | None = None,
) -> dict[str, Any]:
    """Extract the source-comparison verdict from one cohort stdout log."""
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = ANSI_RE.sub("", raw)

    result: dict[str, Any] = {
        "logPath": None,  # filled by caller (repo-relative)
        "logModifiedAt": datetime.fromtimestamp(
            path.stat().st_mtime, tz=timezone.utc
        ).isoformat(timespec="seconds"),
        "durationSeconds": None,
        "summary": None,
        "failedContracts": [],
        "allowedDiffAddresses": [],
        "outcome": None,
        "errorLine": None,
        "failure": None,
        "matchedBlockers": [],
        "digestPaths": [],
    }

    duration = DURATION_RE.search(text)
    if duration:
        result["durationSeconds"] = float(duration.group(1))

    # Counts are read only from the source block: the bytecode summary emits
    # identically worded lines, so an unscoped regex would mix the two.
    start = text.find(SOURCE_SUMMARY_HEADER)
    if start != -1:
        end = text.find(BYTECODE_SUMMARY_HEADER, start)
        block = text[start:] if end == -1 else text[start:end]
        counts = {key: int(value) for key, value in COUNT_RE.findall(block)}
        result["summary"] = {
            "analyzed": counts.get("Total contracts analyzed"),
            "exactMatches": counts.get("Exact matches"),
            "allowedDiffs": counts.get("Allowed diffs"),
            "failures": counts.get("Failures"),
            "filesWithDiffs": counts.get("Total files with non-zero diffs"),
        }
        bullets_from = block.find(UNCOVERED_SOURCE_HEADER)
        if bullets_from != -1:
            for match in FAILED_BULLET_RE.finditer(block[bullets_from:]):
                result["failedContracts"].append(
                    {
                        "address": match.group("address"),
                        "contractName": match.group("name"),
                        "filesWithDiffs": int(match.group("files")),
                    }
                )

    for line in text.splitlines():
        if "Allowed source diff" in line:
            result["allowedDiffAddresses"].extend(
                m.group(0) for m in ADDRESS_RE.finditer(line)
            )

    # Diff renderings are the replayable artifact behind a diff finding; keep a
    # pointer so the report can send a reader straight to the evidence.
    result["digestPaths"] = sorted(
        set(re.findall(r"digest/\d+/diffs/0x[0-9a-fA-F]{40}/[^\s│]+\.html", text))
    )[:20]

    # A blocker only explains a failure when this log carries its signature.
    # An entry with no signature can never absorb one, so an unrecognised
    # failure reaches the reader instead of disappearing into a known gap.
    result["matchedBlockers"] = sorted(
        blocker_id
        for blocker_id, pattern in (blocker_signatures or {}).items()
        if pattern.search(text)
    )

    if result["summary"] is None:
        result["outcome"], result["errorLine"], result["failure"] = classify_crash(
            text, repository_url, explorer_hostname
        )
    elif result["summary"]["failures"]:
        result["outcome"] = "source-diff"
    elif result["summary"]["allowedDiffs"]:
        result["outcome"] = "source-allowed-diff"
    else:
        result["outcome"] = "source-match"
    return result


def deployment_outcome(
    cohort: dict[str, Any], log: dict[str, Any], address: str
) -> tuple[str, dict[str, Any]]:
    """Attribute a cohort log's finding to one address inside that cohort."""
    detail: dict[str, Any] = {}
    lowered = address.lower()

    failed = {
        item["address"].lower(): item for item in log["failedContracts"]
    }
    if lowered in failed:
        detail = {
            "filesWithDiffs": failed[lowered]["filesWithDiffs"],
            "diffyscanContractName": failed[lowered]["contractName"],
        }
        return "source-diff", detail

    if lowered in {a.lower() for a in log["allowedDiffAddresses"]}:
        return "source-allowed-diff", detail

    outcome = log["outcome"]
    if outcome == "source-diff":
        # The cohort had an uncovered diff elsewhere; this address itself
        # matched, and saying otherwise would overstate the finding.
        return "source-match", detail
    if outcome == "source-allowed-diff":
        return "source-match", detail
    if outcome in CRASH_OUTCOMES:
        detail = {
            "cohortAborted": True,
            "errorLine": log["errorLine"],
            "failure": log["failure"],
        }
    return outcome, detail


def sha256_file(path: Path) -> str | None:
    """Hash one file so a report can name the method edition that produced it."""
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative_to_repo(path: Path | None, repo_root: Path) -> str | None:
    """Repo-relative when possible: an absolute path in a published report says
    more about the machine that ran it than about the run."""
    if path is None:
        return None
    try:
        return str(path.relative_to(repo_root))
    except ValueError:
        return str(path)


def load_explorer_hosts(repo_root: Path) -> dict[str, str]:
    """Explorer hostname per networkId, with the default under the empty key.

    Read from the repo's own networks.json rather than restated here, so a
    crash can be attributed to the explorer this cohort was actually pointed at.
    """
    path = repo_root / "diffyscan" / "networks.json"
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    default = (data.get("default") or {}).get("explorer_hostname")
    hosts: dict[str, str] = {"": default} if default else {}
    for network_id, entry in (data.get("networks") or {}).items():
        hostname = (entry or {}).get("explorer_hostname") or default
        if hostname:
            hosts[network_id] = hostname
    return hosts


def load_known_blockers(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {"blockers": []}
    return json.loads(path.read_text(encoding="utf-8"))


def blocker_signatures(registry: dict[str, Any]) -> dict[str, re.Pattern[str]]:
    """Compile the signatures that let a blocker claim a failure.

    A blocker with no signature compiles to nothing on purpose: it has never
    been observed in a sweep log, so it is not allowed to explain one.
    """
    compiled: dict[str, re.Pattern[str]] = {}
    for blocker in registry.get("blockers") or []:
        signature = blocker.get("logSignature")
        if signature:
            compiled[blocker["id"]] = re.compile(signature, re.IGNORECASE)
    return compiled


def evaluate_blockers(
    registry: dict[str, Any], cohort_reports: list[dict[str, Any]], today: date
) -> list[dict[str, Any]]:
    """Report each documented blocker against what this sweep actually observed."""
    evaluated: list[dict[str, Any]] = []
    for blocker in registry.get("blockers") or []:
        networks = set(blocker.get("appliesToNetworkIds") or [])
        failing = [
            report
            for report in cohort_reports
            if report["networkId"] in networks
            and report["outcome"] not in CLEAN_OUTCOMES
        ]
        matched = [r["cohortId"] for r in failing if blocker["id"] in r["matchedBlockers"]]
        as_of = blocker.get("asOf")
        reverify_by = blocker.get("reverifyBy")
        evaluated.append(
            {
                "id": blocker["id"],
                "claim": blocker.get("claim"),
                "asOf": as_of,
                "ageDays": (today - date.fromisoformat(as_of)).days if as_of else None,
                "reverifyBy": reverify_by,
                "reverifyOverdue": bool(
                    reverify_by and date.fromisoformat(reverify_by) < today
                ),
                "hasSignature": bool(blocker.get("logSignature")),
                "evidenceRef": blocker.get("evidenceRef"),
                "matchedCohorts": sorted(matched),
                # Failing cohorts on this blocker's networks that it does not
                # explain. These are findings, not known gaps.
                "unexplainedCohorts": sorted(
                    r["cohortId"] for r in failing if r["cohortId"] not in set(matched)
                ),
                "exercisedThisRun": bool(failing),
            }
        )
    return evaluated


def failure_clusters(cohort_reports: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Group sweep failures by what failed, without judging whether they are one.

    Weakest-link composition treats findings as independent members. A rate
    limit, an expired token or a dropped uplink breaks that assumption: it
    produces one cause wearing N cohort failures. This publishes the grouping
    and the share it covers; deciding whether a cluster is a single common-mode
    finding is the report's judgement, not a threshold in here.
    """
    with_logs = [r for r in cohort_reports if r["outcome"] != "not-run"]
    clusters: dict[tuple[Any, ...], dict[str, Any]] = {}
    for report in cohort_reports:
        # A source diff is a per-entry finding, not a failure of the sweep.
        if report["outcome"] in CLEAN_OUTCOMES or report["outcome"] == "source-diff":
            continue
        failure = report.get("failure") or {}
        key = (report["outcome"], failure.get("hostKind"), failure.get("httpStatus"))
        cluster = clusters.setdefault(
            key,
            {
                "outcome": key[0],
                "hostKind": key[1],
                "httpStatus": key[2],
                "rateLimited": False,
                "hosts": set(),
                "cohorts": [],
            },
        )
        cluster["cohorts"].append(report["cohortId"])
        cluster["rateLimited"] |= bool(failure.get("rateLimited"))
        if failure.get("failingHost"):
            cluster["hosts"].add(failure["failingHost"])
    return [
        {
            **cluster,
            "hosts": sorted(cluster["hosts"]),
            "cohorts": sorted(cluster["cohorts"]),
            "cohortCount": len(cluster["cohorts"]),
            "cohortsWithLogs": len(with_logs),
            "cohortsTotal": len(cohort_reports),
        }
        for cluster in sorted(
            clusters.values(), key=lambda c: (-len(c["cohorts"]), c["outcome"])
        )
    ]


def collect(
    repo_root: Path,
    ledger_path: Path,
    logs_dir: Path,
    generated_dir: Path,
    known_blockers: dict[str, Any] | None = None,
    known_blockers_path: Path | None = None,
) -> dict[str, Any]:
    rdc = load_renderer(repo_root)
    cohorts, blockers, deployments_by_id = project_cohorts(rdc, repo_root, ledger_path)
    registry = known_blockers or {"blockers": []}
    signatures = blocker_signatures(registry)
    explorer_hosts = load_explorer_hosts(repo_root)

    projected_ids: set[str] = set()
    cohort_reports: list[dict[str, Any]] = []
    per_deployment: dict[str, dict[str, Any]] = {}

    for cohort_id in sorted(cohorts):
        cohort = cohorts[cohort_id]
        projected_ids.update(cohort["deploymentIds"])
        log_path = logs_dir / f"{cohort_id}.log"
        config_path = generated_dir / f"{cohort_id}.json"

        if log_path.is_file():
            log = parse_log(
                log_path,
                repository_url=cohort["repositoryUrl"],
                explorer_hostname=explorer_hosts.get(
                    cohort["networkId"], explorer_hosts.get("")
                ),
                blocker_signatures=signatures,
            )
            log["logPath"] = str(log_path.relative_to(repo_root))
        else:
            log = {
                "logPath": None,
                "logModifiedAt": None,
                "durationSeconds": None,
                "summary": None,
                "failedContracts": [],
                "allowedDiffAddresses": [],
                "outcome": "not-run",
                "errorLine": None,
                "failure": None,
                "matchedBlockers": [],
                "digestPaths": [],
            }

        cohort_reports.append(
            {
                "cohortId": cohort_id,
                "networkId": cohort["networkId"],
                "repositoryUrl": cohort["repositoryUrl"],
                "commit": cohort["commit"],
                "contracts": len(cohort["deploymentIds"]),
                "configPresent": config_path.is_file(),
                **log,
            }
        )

        for address, deployment_id in cohort["deploymentIdByAddress"].items():
            outcome, detail = deployment_outcome(cohort, log, address)
            per_deployment[deployment_id] = {
                "outcome": outcome,
                "cohortId": cohort_id,
                "repositoryUrl": cohort["repositoryUrl"],
                "commit": cohort["commit"],
                "logPath": log["logPath"],
                **detail,
            }

    for key, deployment_ids in blockers.items():
        outcome, reason = OUTSIDE_SWEEP_OUTCOMES.get(key, ("not-projected", key))
        for deployment_id in deployment_ids:
            if deployment_id in per_deployment:
                continue
            per_deployment[deployment_id] = {
                "outcome": outcome,
                "reason": reason,
                "blocker": key,
            }

    for deployment_id in deployments_by_id:
        per_deployment.setdefault(
            deployment_id,
            {"outcome": "not-projected", "reason": "unclassified", "blocker": None},
        )

    by_outcome: dict[str, int] = {}
    for record in per_deployment.values():
        by_outcome[record["outcome"]] = by_outcome.get(record["outcome"], 0) + 1

    stale = [
        report["cohortId"]
        for report in cohort_reports
        if report["logModifiedAt"] is None
        or report["logModifiedAt"]
        < datetime.fromtimestamp(
            ledger_path.stat().st_mtime, tz=timezone.utc
        ).isoformat(timespec="seconds")
    ]

    collected = datetime.now(timezone.utc)
    return {
        "kind": "diffyscan-collection",
        "collectedAt": collected.isoformat(timespec="seconds"),
        # Which edition of this classifier produced the outcomes below. Two
        # collections of the same ledger by different editions are not
        # comparable, and the report is meant to be diffed against its
        # predecessors.
        "method": {
            "collector": Path(__file__).name,
            "collectorSha256": sha256_file(Path(__file__).resolve()),
            "knownBlockers": relative_to_repo(known_blockers_path, repo_root),
            "knownBlockersSha256": (
                sha256_file(known_blockers_path) if known_blockers_path else None
            ),
        },
        "ledger": str(ledger_path.relative_to(repo_root)),
        "ledgerSha256": sha256_file(ledger_path),
        "ledgerModifiedAt": datetime.fromtimestamp(
            ledger_path.stat().st_mtime, tz=timezone.utc
        ).isoformat(timespec="seconds"),
        "bytecodeComparison": "skipped (--skip-binary-comparison)",
        "totals": {
            "deployments": len(deployments_by_id),
            "projected": len(projected_ids),
            "cohorts": len(cohorts),
            "byOutcome": by_outcome,
        },
        "cohortsWithLogsOlderThanLedger": stale,
        "outsideSweepByReason": {
            OUTSIDE_SWEEP_OUTCOMES.get(key, ("not-projected", key))[1]: sorted(ids)
            for key, ids in blockers.items()
            if ids
        },
        "failureClusters": failure_clusters(cohort_reports),
        "knownBlockers": evaluate_blockers(registry, cohort_reports, collected.date()),
        "cohorts": cohort_reports,
        "deployments": per_deployment,
    }


def print_summary(report: dict[str, Any]) -> None:
    totals = report["totals"]
    print("Diffyscan source-provenance collection")
    print(f"  deployments:        {totals['deployments']}")
    print(f"  projected/cohorts:  {totals['projected']} across {totals['cohorts']}")
    print(f"  bytecode:           {report['bytecodeComparison']}")
    for outcome, count in sorted(
        totals["byOutcome"].items(), key=lambda item: (-item[1], item[0])
    ):
        print(f"  {outcome:<24}{count}")
    if report["cohortsWithLogsOlderThanLedger"]:
        print(
            "  logs older than the ledger: "
            f"{len(report['cohortsWithLogsOlderThanLedger'])} cohort(s)"
        )
    if report["failureClusters"]:
        print("  failure clusters (one cause may wear many cohort failures):")
        for cluster in report["failureClusters"]:
            host = ", ".join(cluster["hosts"]) or "-"
            status = cluster["httpStatus"] or "-"
            print(
                f"    {cluster['cohortCount']:>3}/{cluster['cohortsTotal']} "
                f"{cluster['outcome']} "
                f"[{cluster['hostKind'] or 'n/a'} {status} {host}]"
                + ("  rate-limited" if cluster["rateLimited"] else "")
            )
    for blocker in report["knownBlockers"]:
        if not blocker["exercisedThisRun"]:
            print(f"  known blocker {blocker['id']}: not exercised by this run")
        elif blocker["unexplainedCohorts"]:
            print(
                f"  known blocker {blocker['id']}: does NOT explain "
                f"{len(blocker['unexplainedCohorts'])} failing cohort(s) on its "
                "networks — report them as findings"
            )
        if not blocker["hasSignature"]:
            print(
                f"    ! {blocker['id']} carries no logSignature, so it can never "
                "absorb a failure (asOf "
                f"{blocker['asOf']}, {blocker['ageDays']} days old)"
            )
        if blocker["reverifyOverdue"]:
            print(f"    ! {blocker['id']} is past its reverifyBy date")
    for cohort in report["cohorts"]:
        if cohort["outcome"] in CLEAN_OUTCOMES:
            continue
        print(f"  ! {cohort['cohortId']}: {cohort['outcome']}")
        if cohort["errorLine"]:
            print(f"      {cohort['errorLine'][:160]}")
        for failed in cohort["failedContracts"]:
            print(
                f"      {failed['address']} {failed['contractName']} "
                f"({failed['filesWithDiffs']} file(s) with diffs)"
            )


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    repo_root = args.repo_root.resolve()
    ledger_path = (args.ledger or repo_root / "ledger.json").resolve()
    logs_dir = (args.logs_dir or repo_root / "diffyscan" / "logs").resolve()
    generated_dir = (
        args.generated_dir or repo_root / "diffyscan" / "generated"
    ).resolve()

    if not ledger_path.is_file():
        print(f"Ledger not found: {ledger_path}", file=sys.stderr)
        return EXIT_USAGE
    if not logs_dir.is_dir():
        print(
            f"Diffyscan log directory not found: {logs_dir}\n"
            "Run `just diffyscan-sources` before collecting.",
            file=sys.stderr,
        )
        return EXIT_USAGE

    known_blockers_path = args.known_blockers.resolve() if args.known_blockers else None
    report = collect(
        repo_root,
        ledger_path,
        logs_dir,
        generated_dir,
        known_blockers=load_known_blockers(known_blockers_path),
        known_blockers_path=known_blockers_path,
    )

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(
            json.dumps(report, indent=2, sort_keys=False) + "\n", encoding="utf-8"
        )
        print(f"wrote {args.out}")
    print_summary(report)

    needs_attention = any(
        record["outcome"] not in CLEAN_OUTCOMES
        for record in report["deployments"].values()
    )
    return EXIT_ATTENTION if needs_attention else EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
