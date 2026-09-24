// Right panel: one tab per call the assistant has read. Audio player with a
// "now playing" caption, AI analysis, and the full-transcript dialog.

import { audioUrl, getJSON, postJSON } from "./api.js";
import { clock, esc, shortDate } from "./format.js";

const tabs = document.getElementById("call-tabs");
const view = document.getElementById("call-view");
const dialog = document.getElementById("transcript-dialog");
const dialogList = document.getElementById("transcript-list");
const emptyView = view.innerHTML;

const calls = new Map(); // call_id -> { call, transcript }
let activeId = null;
let audio = null;

document.getElementById("transcript-close").addEventListener("click", () => dialog.close());

const turnAt = (turns, sec) => turns.findLast((t) => t.start_sec <= sec + 0.05) || turns[0];

function speaker(s) {
  return `<span class="speaker speaker-${s}">${s}</span>`;
}

function renderTabs() {
  tabs.innerHTML = [...calls.keys()].map((id) =>
    `<button type="button" class="call-tab" role="tab" aria-selected="${id === activeId}" data-call="${id}">Call ${id}</button>`).join("");
}

function showTurn(turn) {
  const caption = view.querySelector("#now-playing");
  if (caption && turn) caption.innerHTML = `<span class="ts">${turn.timestamp}</span>${speaker(turn.speaker)}${esc(turn.text)}`;
  for (const li of dialogList.querySelectorAll(".turn")) li.classList.toggle("active", Number(li.dataset.seq) === turn?.seq);
}

function renderAnalysis(analysis) {
  if (!analysis) {
    return `<section class="section"><h4 class="section-title">Analysis</h4>
      <p class="empty-note">Not analyzed yet.</p>
      <button type="button" class="btn btn-ghost btn-small" id="analyze-btn">Analyze call</button></section>`;
  }
  const moment = (item, label) => `
    <li><button type="button" class="moment" data-sec="${item.start_sec ?? 0}">
      <span class="ts">${item.timestamp ?? ""}</span>
      <span>${label}<span class="why">${esc(item.why ?? "")}</span></span></button></li>`;
  const { sentiment } = analysis;
  return `
    <section class="section"><h4 class="section-title">Summary</h4><p style="margin:0">${esc(analysis.summary)}</p></section>
    <section class="section"><h4 class="section-title">Key moments</h4>
      <ul class="list">${analysis.highlights.map((h) => moment(h, `${speaker(h.speaker)}<q>${esc(h.quote)}</q>`)).join("")}</ul></section>
    <section class="section"><h4 class="section-title">Requested changes</h4>
      <ul class="list">${analysis.requested_changes.map((r) => moment(r,
        `<span class="pill">${esc(r.action)}</span> <span class="pill ${r.final_decision === "CONFIRMED" ? "v-MATCH" : ""}">${esc(r.final_decision)}</span>
         ${esc(r.coverage_code || "")}<span class="why">${esc(r.detail)}</span>`)).join("") || `<li class="empty-note">None.</li>`}</ul></section>
    <section class="section"><h4 class="section-title">Agent promises</h4>
      <ul class="list">${analysis.agent_promises.map((p) => moment(p,
        `${esc(p.coverage_code || "")}<span class="why">${esc(p.detail)}</span>`)).join("") || `<li class="empty-note">None.</li>`}</ul></section>
    <section class="section"><h4 class="section-title">Sentiment</h4>
      <div class="sentiment-row"><span>Member: <strong>${esc(sentiment.member_overall)}</strong></span>
        <span>Agent: <strong>${esc(sentiment.agent_overall)}</strong></span></div>
      <div class="strip" aria-label="Sentiment per turn">${sentiment.timeline.map((t) =>
        `<span class="s-${t.sentiment}" title="#${t.seq} ${t.speaker}: ${t.sentiment}"></span>`).join("")}</div></section>
    <p class="meta">Analysis by ${esc(analysis.model)}</p>`;
}

function render() {
  const { call, transcript } = calls.get(activeId);
  const hasAudio = Boolean(call.has_audio);
  view.innerHTML = `
    <div class="call-head">
      <h3>Call ${call.call_id}</h3>
      <span class="meta">${esc(shortDate(call.call_datetime))} · Agent ${esc(call.agent_name)} · ${clock(call.duration_sec)} · ${esc(call.reason || "")}</span>
    </div>
    ${hasAudio
      ? `<audio id="call-audio" controls preload="metadata" src="${audioUrl(call.call_id)}"></audio>`
      : `<p class="empty-note">Scripted transcript · no recording for this call.</p>`}
    <div id="now-playing" class="now-playing" aria-live="polite"><span class="meta">${hasAudio ? "Press play, or click a moment or citation." : "Click a moment or citation to show that turn."}</span></div>
    <button type="button" class="btn btn-ghost" id="open-transcript">Open full transcript (${transcript.turns.length} turns)</button>
    ${renderAnalysis(call.analysis)}`;

  audio = view.querySelector("#call-audio");
  audio?.addEventListener("timeupdate", () => showTurn(turnAt(transcript.turns, audio.currentTime)));
  view.querySelector("#open-transcript").addEventListener("click", openTranscript);
  view.querySelector("#analyze-btn")?.addEventListener("click", analyze);
  for (const btn of view.querySelectorAll(".moment")) btn.addEventListener("click", () => seek(Number(btn.dataset.sec)));
}

async function analyze(event) {
  const button = event.currentTarget;
  button.disabled = true;
  button.textContent = "Analyzing…";
  try {
    await postJSON(`/api/calls/${activeId}/analyze`);
    await showCall(activeId, { refresh: true });
  } catch (error) {
    button.textContent = error.message;
  }
}

function openTranscript() {
  const { call, transcript } = calls.get(activeId);
  document.getElementById("transcript-title").textContent =
    `Call ${call.call_id} · ${shortDate(call.call_datetime)} · ${call.transcript_source === "WHISPER" ? "Whisper transcript" : "Scripted transcript"}`;
  dialogList.innerHTML = transcript.turns.map((t) => `
    <li class="turn" data-seq="${t.seq}">
      <button type="button" class="ts" data-sec="${t.start_sec}" ${call.has_audio ? "" : "disabled"}>${t.timestamp}</button>
      ${speaker(t.speaker)}<span>${esc(t.text)}</span>
    </li>`).join("");
  for (const btn of dialogList.querySelectorAll(".ts")) btn.addEventListener("click", () => seek(Number(btn.dataset.sec)));
  if (audio) showTurn(turnAt(transcript.turns, audio.currentTime));
  dialog.showModal();
}

function seek(sec) {
  const { transcript } = calls.get(activeId);
  showTurn(turnAt(transcript.turns, sec));
  if (audio) {
    audio.currentTime = sec;
    audio.play().catch(() => {}); // autoplay may be blocked until the first click
  }
}

export async function showCall(callId, { sec = null, refresh = false } = {}) {
  const id = Number(callId);
  if (refresh || !calls.has(id)) {
    const [call, transcript] = await Promise.all([
      getJSON(`/api/calls/${id}`),
      calls.get(id)?.transcript ?? getJSON(`/api/calls/${id}/transcript`),
    ]);
    calls.set(id, { call, transcript });
  }
  if (activeId !== id || refresh) {
    activeId = id;
    render();
  }
  renderTabs();
  if (sec != null) seek(sec);
}

export function clearCalls() {
  calls.clear();
  activeId = null;
  audio = null;
  tabs.innerHTML = "";
  view.innerHTML = emptyView;
}

tabs.addEventListener("click", (event) => {
  const tab = event.target.closest(".call-tab");
  if (tab) showCall(tab.dataset.call);
});
