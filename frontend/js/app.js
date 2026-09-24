// Chat wiring: sends questions, renders the streamed answer with its tool
// steps, and routes panel events (policy, call, finding) to the side panels.

import { getJSON, postJSON, streamChat } from "./api.js";
import { esc, renderMarkdown } from "./format.js";
import { clearCalls, showCall } from "./call-panel.js";
import { clearPolicy, highlightTransaction, loadPolicy, refreshFindings } from "./policy-panel.js";

const messages = document.getElementById("messages");
const emptyState = document.getElementById("chat-empty");
const composer = document.getElementById("composer");
const input = document.getElementById("composer-input");
const sendButton = document.getElementById("send-btn");

let sessionId = null;
let busy = false;
let memberNumber = null; // from the last find_policy call, needed to load the policy panel

// ---------------------------------------------------------------- messages

function scrollToEnd() {
  messages.scrollTop = messages.scrollHeight;
}

function addUserMessage(text) {
  emptyState.hidden = true;
  const el = document.createElement("div");
  el.className = "msg msg-user";
  el.textContent = text;
  messages.append(el);
  scrollToEnd();
}

function stepDetail(input = {}) {
  if (input.call_id) return `Call ${input.call_id}`;
  if (input.transaction_id) return `Txn ${input.transaction_id}`;
  if (input.verdict) return `${input.verdict} · ${input.coverage_code || "vehicle"}`;
  return [input.policy_number, input.coverage_code].filter(Boolean).join(" · ");
}

// One assistant turn: text parts and tool-step lists, in the order they stream.
function assistantMessage() {
  const root = document.createElement("div");
  root.className = "msg msg-assistant";
  const pending = document.createElement("div");
  pending.className = "pending";
  pending.innerHTML = "<span></span><span></span><span></span>";
  root.append(pending);
  messages.append(root);

  let answer = null;
  let buffer = "";
  let steps = null;
  const place = (el) => { root.insertBefore(el, pending); scrollToEnd(); };

  return {
    text(chunk) {
      if (!answer) {
        answer = document.createElement("div");
        answer.className = "answer";
        buffer = "";
        steps = null;
        place(answer);
      }
      buffer += chunk;
      answer.innerHTML = renderMarkdown(buffer);
      scrollToEnd();
    },
    step(event) {
      if (!steps) {
        steps = document.createElement("ol");
        steps.className = "steps";
        answer = null;
        place(steps);
      }
      const li = document.createElement("li");
      li.className = "step running";
      li.dataset.tool = event.tool;
      li.innerHTML = `<span class="step-icon"></span><span>${esc(event.label)}</span><span class="step-detail">${esc(stepDetail(event.input))}</span>`;
      steps.append(li);
      scrollToEnd();
    },
    stepDone(event) {
      const li = root.querySelector(`.step.running[data-tool="${event.tool}"]`);
      if (!li) return;
      li.classList.replace("running", event.ok ? "ok" : "failed");
      if (!event.ok) li.title = event.error;
    },
    error(message) {
      const box = document.createElement("div");
      box.className = "error-box";
      box.textContent = message;
      place(box);
    },
    finish() {
      pending.remove();
      for (const li of root.querySelectorAll(".step.running")) li.classList.replace("running", "failed");
    },
  };
}

// ---------------------------------------------------------------- sending

function setBusy(value) {
  busy = value;
  sendButton.disabled = value;
  sendButton.textContent = value ? "Working…" : "Send";
}

async function send(text) {
  text = text.trim();
  if (!text || busy) return;
  setBusy(true);
  addUserMessage(text);
  const reply = assistantMessage();
  const panelError = (error) => reply.error(`Could not load panel data: ${error.message}`);

  try {
    await streamChat(text, sessionId, (event) => {
      switch (event.type) {
        case "session": sessionId = event.session_id; break;
        case "text": reply.text(event.text); break;
        case "tool":
          if (event.tool === "find_policy") memberNumber = event.input.member_number;
          reply.step(event);
          break;
        case "tool_done": reply.stepDone(event); break;
        case "policy": loadPolicy(event.policy_number, memberNumber).catch(panelError); break;
        case "call": showCall(event.call_id, { refresh: true }).catch(panelError); break;
        case "finding": refreshFindings().catch(panelError); break;
        case "error": reply.error(event.message); break;
      }
    });
  } catch (error) {
    reply.error(`Connection problem: ${error.message}`);
  } finally {
    reply.finish();
    setBusy(false);
    input.focus();
  }
}

// ---------------------------------------------------------------- controls

composer.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = input.value;
  input.value = "";
  input.style.height = "";
  send(text);
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    composer.requestSubmit();
  }
});

input.addEventListener("input", () => {
  input.style.height = "auto";
  input.style.height = `${Math.min(input.scrollHeight, 160)}px`;
});

for (const button of document.querySelectorAll(".suggestion")) {
  button.addEventListener("click", () => send(button.textContent));
}

const reviewForm = document.getElementById("review-form");
reviewForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const member = reviewForm.member.value.trim();
  const policy = reviewForm.policy.value.trim();
  const coverage = reviewForm.coverage.value;
  const scope = coverage === "all" ? "all" : coverage;
  send(`Review ${scope} changes on policy ${policy}, member ${member}.`);
});

for (const button of reviewForm.querySelectorAll("[data-policy]")) {
  button.addEventListener("click", () => {
    reviewForm.member.value = button.dataset.member;
    reviewForm.policy.value = button.dataset.policy;
  });
}

// Citation chips anywhere on the page: [Call N · m:ss] and [Txn N]
document.addEventListener("click", (event) => {
  const chip = event.target.closest(".cite:not(.cite-static)");
  if (!chip) return;
  if (chip.dataset.call) showCall(chip.dataset.call, { sec: Number(chip.dataset.sec) }).catch(() => {});
  if (chip.dataset.txn) highlightTransaction(chip.dataset.txn);
});

document.getElementById("reset-btn").addEventListener("click", async () => {
  if (busy) return;
  await postJSON("/api/demo/reset");
  sessionId = null;
  memberNumber = null;
  for (const el of messages.querySelectorAll(".msg")) el.remove();
  emptyState.hidden = false;
  clearPolicy();
  clearCalls();
});

// Model badge: real Claude or the simulated one
getJSON("/api/health").then(({ model, offline }) => {
  const badge = document.getElementById("model-badge");
  const mock = model === "mock-claude";
  badge.textContent = offline ? "Offline preview" : mock ? "Simulated Claude" : model;
  badge.classList.add(mock || offline ? "badge-mock" : "badge-live");
  badge.title = offline ? "Recorded demo: replays saved reviews, no server or API"
    : mock ? "MOCK_CLAUDE=1: answers are simulated, no API calls" : "Answers from the Claude API";
}).catch(() => {
  document.getElementById("model-badge").textContent = "API offline";
});
