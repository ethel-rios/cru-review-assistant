// Offline stand-in for frontend/js/api.js, bundled by scripts/build_offline_demo.py.
// Serves recorded API responses and replays recorded chat streams, so the page
// works from a single HTML file with no server, database or Claude API.

const DATA = window.CRU_DEMO_DATA; // { get: {url: json}, conversations: [{question, events}], audio: {callId: dataUri} }
const DELAY_MS = { session: 0, text: 18, tool: 350, tool_done: 250, policy: 60, call: 60, finding: 120 };
const findings = new Map(); // policy number -> findings recorded so far in this page session
let lastPolicy = null;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const clone = (value) => JSON.parse(JSON.stringify(value));
const normalize = (text) => text.toLowerCase().replace(/\s+/g, " ").replace(/[.\s]+$/, "").trim();
const offlineError = () => new Error("Not available in the offline preview.");

export async function getJSON(url) {
  await sleep(120);
  const findingsUrl = url.match(/^\/api\/policies\/([^/?]+)\/findings$/);
  if (findingsUrl) return clone(findings.get(decodeURIComponent(findingsUrl[1])) || []);
  if (url in DATA.get) return clone(DATA.get[url]);
  throw offlineError();
}

export async function postJSON(url) {
  if (url === "/api/demo/reset") {
    findings.clear();
    return { ok: true };
  }
  throw offlineError();
}

export const audioUrl = (callId) => DATA.audio[callId] || "";

export async function streamChat(message, sessionId, onEvent) {
  const recorded = DATA.conversations.find((c) => normalize(c.question) === normalize(message));
  const events = recorded ? recorded.events : [
    { type: "session", session_id: "offline" },
    { type: "text", text: "This offline preview replays the recorded demo reviews only. Pick a suggested question, " +
      "or an example policy on the left with **Rental reimbursement** or **All coverages**." },
    { type: "done" },
  ];
  for (const event of events) {
    await sleep(DELAY_MS[event.type] ?? 0);
    if (event.type === "policy") lastPolicy = event.policy_number;
    if (event.type === "finding") {
      const f = event.finding;
      const key = `${f.transaction_id}|${f.call_id}|${f.coverage_code}`;
      const list = (findings.get(lastPolicy) || []).filter((x) => `${x.transaction_id}|${x.call_id}|${x.coverage_code}` !== key);
      findings.set(lastPolicy, [...list, f]);
    }
    onEvent(clone(event));
  }
}
