"""Tests for the validate-ledger skill's own classifiers.

The skill's report is a product of the ledger *and* the edition that read it,
so a classifier that quietly changes its mind changes every finding downstream
of it. These cover the two judgements a reader cannot re-derive from the JSON:
how a crashed cohort is attributed to the addresses inside it, and what the
public-refs gap buckets actually claim.
"""

from __future__ import annotations

from typing import Any

import collect_diffyscan as collector
from check_public_refs import collect_gaps


def contract_block(address: str, files: int, identical: int) -> str:
    return (
        f" 🟢 [OKAY] Contract: {address}\n"
        " 🟢 [OKAY] Blockchain explorer Hostname: api.bscscan.com\n"
        " 🔵 [INFO] Diffing...\n"
        f" 🔵 [INFO] Files found: {files} / {files}\n"
        f" 🔵 [INFO] Identical files: {identical} / {files}\n"
    )


COMPARED = "0x1111111111111111111111111111111111111111"
CRASHED = "0x2222222222222222222222222222222222222222"
UNREACHED = "0x3333333333333333333333333333333333333333"


def crashed_cohort_log() -> str:
    """A cohort that compares one address, dies on the next, never reaches the third."""
    return (
        contract_block(COMPARED, 6, 6)
        + f" 🟢 [OKAY] Contract: {CRASHED}\n"
        " 🔵 [INFO] File 1 / 1: ERC1967Proxy.sol\n"
        "Traceback (most recent call last):\n"
        "diffyscan.utils.custom_exceptions.ExplorerError: Failed to communicate "
        "with a remote resource: HTTP error: 404 Client Error: Not Found for "
        "url: https://api.github.com/repos/example/repo/contents/"
        "ERC1967Proxy.sol?ref=eae15a0d\n"
    )


def cohort(*addresses: str) -> dict[str, Any]:
    return {
        "networkId": "eip155:56",
        "repositoryUrl": "https://github.com/example/repo",
        "commit": "eae15a0d",
        "deploymentIdByAddress": {a.lower(): f"eip155:56:{a}" for a in addresses},
        "deploymentIds": [f"eip155:56:{a}" for a in addresses],
    }


def parsed(tmp_path: Any, text: str) -> dict[str, Any]:
    path = tmp_path / "cohort.log"
    path.write_text(text, encoding="utf-8")
    return collector.parse_log(
        path,
        repository_url="https://github.com/example/repo",
        explorer_hostname="api.bscscan.com",
    )


def test_crash_classified_from_the_http_status(tmp_path: Any) -> None:
    log = parsed(tmp_path, crashed_cohort_log())
    assert log["outcome"] == "source-missing-upstream"


def test_address_compared_before_the_crash_keeps_its_own_outcome(tmp_path: Any) -> None:
    """A sibling's crash is evidence about the sibling, not about this address."""
    log = parsed(tmp_path, crashed_cohort_log())
    outcome, detail = collector.deployment_outcome(
        cohort(COMPARED, CRASHED, UNREACHED), log, COMPARED
    )
    assert outcome == "source-match"
    assert detail["comparedBeforeCohortAborted"] is True
    assert (detail["identicalFiles"], detail["filesCompared"]) == (6, 6)


def test_address_the_crash_interrupted_carries_the_crash_outcome(tmp_path: Any) -> None:
    log = parsed(tmp_path, crashed_cohort_log())
    outcome, detail = collector.deployment_outcome(
        cohort(COMPARED, CRASHED, UNREACHED), log, CRASHED
    )
    assert outcome == "source-missing-upstream"
    assert detail["cohortAborted"] is True


def test_address_the_crash_never_reached_is_not_impeached(tmp_path: Any) -> None:
    """Its files were never requested, so its pin is neither confirmed nor denied."""
    log = parsed(tmp_path, crashed_cohort_log())
    outcome, detail = collector.deployment_outcome(
        cohort(COMPARED, CRASHED, UNREACHED), log, UNREACHED
    )
    assert outcome == "not-reached"
    assert detail["cohortOutcome"] == "source-missing-upstream"


def test_partial_comparison_before_a_crash_claims_nothing(tmp_path: Any) -> None:
    """Files differed and the summary that would judge them never printed.

    Whether those diffs are covered by an allowlist is decided in the cohort
    summary, which a crashed run never reaches — so this address gets the
    cohort's outcome rather than a manufactured `source-diff`.
    """
    text = crashed_cohort_log().replace(
        contract_block(COMPARED, 6, 6), contract_block(COMPARED, 6, 4)
    )
    log = parsed(tmp_path, text)
    outcome, _ = collector.deployment_outcome(cohort(COMPARED, CRASHED), log, COMPARED)
    assert outcome == "source-missing-upstream"


def test_blocker_on_networks_with_no_cohort_reports_why_it_is_untestable() -> None:
    registry = {
        "blockers": [
            {
                "id": "example-blocker",
                "claim": "explorer has no API",
                "appliesToNetworkIds": ["eip155:1923"],
                "asOf": "2026-08-17",
                "logSignature": None,
            }
        ]
    }
    from datetime import date

    [evaluated] = collector.evaluate_blockers(registry, [], date(2026, 8, 24))
    assert evaluated["exercisedThisRun"] is False
    assert evaluated["cohortsOnNetworks"] == 0
    assert "no cohort is built" in evaluated["notExercisedReason"]


def test_blocker_whose_cohorts_all_passed_is_reported_as_impeached() -> None:
    """Clean cohorts on the blocker's networks are evidence against the claim.

    "Not exercised" must not read the same way here as it does when no cohort
    exists: there the claim is untestable, here it was tested and failed.
    """
    registry = {
        "blockers": [
            {
                "id": "example-blocker",
                "claim": "explorer has no API",
                "appliesToNetworkIds": ["eip155:1923"],
                "expectedOutcome": "explorer-unavailable",
                "asOf": "2026-08-17",
                "logSignature": None,
            }
        ]
    }
    from datetime import date

    reports = [
        {
            "cohortId": "swellchain__x__deadbeef",
            "networkId": "eip155:1923",
            "outcome": "source-match",
            "matchedBlockers": [],
        }
    ]
    [evaluated] = collector.evaluate_blockers(registry, reports, date(2026, 8, 24))
    assert evaluated["exercisedThisRun"] is False
    assert evaluated["cohortsOnNetworks"] == 1
    reason = evaluated["notExercisedReason"]
    assert "contradicts" in reason
    assert "explorer-unavailable" in reason


def test_no_public_refs_and_no_source_still_counts_audit_pointers() -> None:
    """The bucket must not read as 'no evidence at all' for an audited entry."""
    ledger = {
        "deployments": [
            {
                "deploymentId": "eip155:1:0xabc",
                "source": None,
                "auditReportRefs": ["https://example.invalid/report.pdf"],
            }
        ]
    }
    gaps = collect_gaps(ledger, [])
    assert gaps["noPublicRefsAndNoSource"] == [
        {"deploymentId": "eip155:1:0xabc", "auditReportRefs": 1}
    ]
