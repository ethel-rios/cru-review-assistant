"""Audit findings: requested / promised on a call vs. applied to the policy.

The chatbot decides the verdict; this module validates the references and
stores it in audit_findings (one finding per policy + transaction + call + coverage).
"""

from ..db import one, write_conn

VERDICTS = ("MATCH", "MISMATCH", "NOT_APPLIED", "NO_CALL_EVIDENCE")


class InvalidFinding(ValueError):
    pass


def record_finding(policy_number: str, verdict: str, explanation: str, model: str,
                   coverage_code: str | None = None, transaction_id: int | None = None,
                   call_id: int | None = None, segment_seq: int | None = None,
                   requested: str | None = None, applied: str | None = None) -> dict:
    if verdict not in VERDICTS:
        raise InvalidFinding(f"verdict must be one of {', '.join(VERDICTS)}.")
    policy = one("SELECT id FROM policies WHERE policy_number = ?", (policy_number,))
    if not policy:
        raise InvalidFinding(f"No policy {policy_number}.")
    policy_id = policy["id"]
    if transaction_id is not None and not one(
            "SELECT 1 FROM transactions WHERE id = ? AND policy_id = ?", (transaction_id, policy_id)):
        raise InvalidFinding(f"Transaction {transaction_id} does not belong to policy {policy_number}.")
    if call_id is not None and not one(
            "SELECT 1 FROM calls WHERE id = ? AND policy_id = ?", (call_id, policy_id)):
        raise InvalidFinding(f"Call {call_id} does not belong to policy {policy_number}.")
    segment_id = None
    if segment_seq is not None:
        if call_id is None:
            raise InvalidFinding("segment_seq needs a call_id.")
        segment = one("SELECT id FROM call_segments WHERE call_id = ? AND seq = ?", (call_id, segment_seq))
        if not segment:
            raise InvalidFinding(f"Call {call_id} has no turn #{segment_seq}.")
        segment_id = segment["id"]

    with write_conn() as conn:
        # Re-running an audit replaces the earlier finding instead of duplicating it.
        conn.execute(
            """DELETE FROM audit_findings WHERE policy_id = ? AND transaction_id IS ?
               AND call_id IS ? AND coverage_code IS ?""",
            (policy_id, transaction_id, call_id, coverage_code),
        )
        cursor = conn.execute(
            """INSERT INTO audit_findings (policy_id, transaction_id, call_id, segment_id, coverage_code,
                                           verdict, requested, applied, explanation, model)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (policy_id, transaction_id, call_id, segment_id, coverage_code,
             verdict, requested, applied, explanation, model),
        )
        finding_id = cursor.lastrowid
    return one(
        """SELECT f.id, f.verdict, f.coverage_code, f.transaction_id, f.call_id, f.requested, f.applied,
                  f.explanation, s.seq AS segment_seq, s.start_sec, s.speaker, s.text AS quote
           FROM audit_findings f LEFT JOIN call_segments s ON s.id = f.segment_id WHERE f.id = ?""",
        (finding_id,),
    )


def forget_simulated_output() -> None:
    """Drop analyses and findings written in MOCK_CLAUDE mode, so real runs never reuse them."""
    with write_conn() as conn:
        conn.execute("DELETE FROM audit_findings WHERE model = 'mock-claude'")
        conn.execute("DELETE FROM call_analysis WHERE model = 'mock-claude'")


def reset_ai_output() -> None:
    """Clear cached analyses and findings so the demo can replay the full flow."""
    with write_conn() as conn:
        conn.execute("DELETE FROM audit_findings")
        conn.execute("DELETE FROM call_analysis")
