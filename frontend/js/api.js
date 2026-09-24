// Thin wrappers over the backend API (backend/api/*).

async function parse(response) {
  if (response.ok) return response.json();
  const body = await response.json().catch(() => ({}));
  throw new Error(body.detail || `${response.status} ${response.statusText}`);
}

export const getJSON = (url) => fetch(url).then(parse);
export const postJSON = (url) => fetch(url, { method: "POST" }).then(parse);
export const audioUrl = (callId) => `/api/calls/${callId}/audio`;

// POST /api/chat answers with Server-Sent Events; EventSource only does GET,
// so read the stream by hand and call onEvent for every event.
export async function streamChat(message, sessionId, onEvent) {
  const response = await fetch("/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message, session_id: sessionId }),
  });
  if (!response.ok) throw new Error(`Chat request failed (${response.status})`);

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let end;
    while ((end = buffer.indexOf("\n\n")) >= 0) {
      const chunk = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      const data = chunk.split("\n").filter((l) => l.startsWith("data: ")).map((l) => l.slice(6)).join("\n");
      if (data) onEvent(JSON.parse(data));
    }
  }
}
