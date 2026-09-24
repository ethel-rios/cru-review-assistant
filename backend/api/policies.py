from fastapi import APIRouter, HTTPException

from .. import queries

router = APIRouter(prefix="/api/policies", tags=["policies"])


@router.get("/{policy_number}")
def get_policy(policy_number: str, member_number: str) -> dict:
    """Validate member + policy and return the policy context panel data."""
    result = queries.find_policy(member_number, policy_number)
    if not result["found"]:
        raise HTTPException(404, result["error"])
    return result


@router.get("/{policy_number}/changes")
def get_changes(policy_number: str, coverage_code: str | None = None, change_type: str | None = None,
                date_from: str | None = None, date_to: str | None = None) -> list[dict]:
    return queries.get_policy_changes(policy_number, coverage_code, change_type, date_from, date_to)


@router.get("/{policy_number}/coverages")
def get_coverages(policy_number: str, coverage_code: str | None = None,
                  as_of: str | None = None) -> list[dict]:
    return queries.get_coverages(policy_number, coverage_code, as_of)


@router.get("/{policy_number}/calls")
def get_calls(policy_number: str, date_from: str | None = None, date_to: str | None = None) -> list[dict]:
    return queries.list_calls(policy_number, date_from, date_to)


@router.get("/{policy_number}/findings")
def get_findings(policy_number: str) -> list[dict]:
    return queries.list_audit_findings(policy_number)
