// Left panel: member, policy, findings, vehicles, coverages in force and change history.

import { getJSON } from "./api.js";
import { esc, renderMarkdown } from "./format.js";

const view = document.getElementById("policy-view");
let current = null; // { policyNumber, changes }

const VERDICT_LABEL = {
  MATCH: "Match",
  MISMATCH: "Mismatch",
  NOT_APPLIED: "Not applied",
  NO_CALL_EVIDENCE: "No call evidence",
};

function changeText(t) {
  if (t.old_rental_tier || t.new_rental_tier) return `${t.old_rental_tier || "—"} → ${t.new_rental_tier || "removed"}`;
  if (t.old_deductible != null) return `Deductible $${t.old_deductible.toLocaleString()} → $${t.new_deductible.toLocaleString()}`;
  return [t.old_value_text, t.new_value_text].filter(Boolean).join(" → ");
}

function renderChanges() {
  const filter = view.querySelector("#change-filter")?.value || "";
  const rows = current.changes.filter((t) => !filter || t.coverage_code === filter);
  view.querySelector("#change-list").innerHTML = rows.map((t) => `
    <li class="row" data-txn="${t.transaction_id}">
      <div class="row-head"><strong>Txn ${t.transaction_id} · ${esc(t.change_type)} ${esc(t.coverage_code || t.target)}</strong>
        <span class="meta">${esc(t.transaction_date)}</span></div>
      <span>${esc(changeText(t))}</span>
      <span class="meta">${esc(t.vehicle || "Policy level")} · ${esc(t.channel)} · term ${t.term_number}</span>
    </li>`).join("") || `<li class="empty-note">No changes for this coverage.</li>`;
}

export async function loadPolicy(policyNumber, memberNumber) {
  const [policy, changes] = await Promise.all([
    getJSON(`/api/policies/${encodeURIComponent(policyNumber)}?member_number=${encodeURIComponent(memberNumber)}`),
    getJSON(`/api/policies/${encodeURIComponent(policyNumber)}/changes`),
  ]);
  current = { policyNumber, changes };
  const { member, policy: p, current_term: term } = policy;
  const codes = [...new Set(changes.map((t) => t.coverage_code).filter(Boolean))];

  view.innerHTML = `
    <div class="card">
      <h3>${esc(member.full_name)}</h3>
      <span class="meta">Member ${esc(member.member_number)} · ${esc(member.eligibility)}${member.military_branch ? `, ${esc(member.military_branch)}` : ""}</span>
      <dl class="kv">
        <dt>Policy</dt><dd class="mono">${esc(p.policy_number)}</dd>
        <dt>State</dt><dd>${esc(p.issue_state)} · ${esc(member.city)}</dd>
        <dt>Since</dt><dd>${esc(p.start_date)} · ${policy.term_count_to_date} terms</dd>
        ${term ? `<dt>Current term</dt><dd>#${term.term_number} · ${esc(term.start_date)} → ${esc(term.end_date)}</dd>` : ""}
      </dl>
    </div>
    <section class="section">
      <h3 class="section-title">Findings <span id="finding-count" class="pill">0</span></h3>
      <ul id="finding-list" class="list"></ul>
    </section>
    <section class="section">
      <h3 class="section-title">Vehicles</h3>
      <ul class="list">${policy.vehicles.map((v) => `
        <li class="row"><strong>${esc(`${v.model_year} ${v.make} ${v.model}`)}</strong>
          <span class="meta mono">VIN ${esc(v.vin)}</span>
          <span class="meta">${v.removed_on ? `Removed ${esc(v.removed_on)}` : `Since ${esc(v.added_on)}`}</span></li>`).join("")}</ul>
    </section>
    <section class="section">
      <h3 class="section-title">Coverages in force</h3>
      <table class="cov-table">
        <thead><tr><th>Coverage</th><th>Vehicle</th><th>Limit / tier</th></tr></thead>
        <tbody>${policy.active_coverages.map((c) => `
          <tr><td>${esc(c.coverage_code)}</td><td>${esc(c.vehicle.replace(/^\d{4} /, ""))}</td>
            <td>${c.rental_tier ? `${esc(c.rental_tier)} · ${esc(c.rental_class)}` : esc(c.limit_text || (c.deductible != null ? `Ded. $${c.deductible}` : "—"))}</td></tr>`).join("")}</tbody>
      </table>
    </section>
    <section class="section">
      <h3 class="section-title">Change history
        <select id="change-filter" class="filter" aria-label="Filter changes by coverage">
          <option value="">All</option>${codes.map((c) => `<option>${esc(c)}</option>`).join("")}
        </select></h3>
      <ul id="change-list" class="list"></ul>
    </section>`;
  view.hidden = false;
  view.querySelector("#change-filter").addEventListener("change", renderChanges);
  renderChanges();
  await refreshFindings();
}

export async function refreshFindings() {
  if (!current) return;
  const findings = await getJSON(`/api/policies/${encodeURIComponent(current.policyNumber)}/findings`);
  view.querySelector("#finding-count").textContent = findings.length;
  view.querySelector("#finding-list").innerHTML = findings.map((f) => `
    <li class="row finding v-${f.verdict}-row">
      <div class="row-head"><span class="pill v-${f.verdict}">${VERDICT_LABEL[f.verdict] || f.verdict}</span>
        <span class="meta">${esc(f.coverage_code || "Vehicle")}${f.transaction_id ? ` · Txn ${f.transaction_id}` : ""}</span></div>
      ${renderMarkdown(f.explanation)}
    </li>`).join("") || `<li class="empty-note">No findings yet.</li>`;
}

export function highlightTransaction(id) {
  if (!current) return;
  const filter = view.querySelector("#change-filter");
  if (filter.value) { filter.value = ""; renderChanges(); }
  const row = view.querySelector(`#change-list [data-txn="${id}"]`);
  if (!row) return;
  row.scrollIntoView({ behavior: "smooth", block: "center" });
  row.classList.remove("flash");
  void row.offsetWidth; // restart the animation
  row.classList.add("flash");
}

export function clearPolicy() {
  current = null;
  view.hidden = true;
  view.innerHTML = "";
}
