# CRU Review Assistant

Hackathon project — TCS x USAA, Property & Casualty (auto).

The **Coverage Response Unit (CRU)** reviews changes made to members' auto policies. Today a reviewer goes through 20+ six-month policy terms, finds the coverage transactions (e.g. rental reimbursement added, removed or modified) and listens to years of member calls to confirm each change is what the member asked for.

This app does that review with an AI chatbot: given a member number and a policy number, it finds the relevant policy changes, reads the calls around them, and flags any mismatch between **what was requested or promised on the phone** and **what the policy records show** — citing the call, the minute and the transaction.

All data is synthetic.

---

## How it works

```
Reviewer ──► Web UI ──► FastAPI backend ──► Chat agent (Claude)
                                                 │  calls fixed tools
                                                 ▼
                                   SQLite database (policies, calls, transcripts)
```

1. The reviewer asks: *"Review rental reimbursement changes on policy AUT-0123456-7103, member 123456."*
2. The **chat agent** (Claude) validates the member and policy, reads the policy's transactions and lists its calls.
3. It reads each call transcript and **analyzes** it: summary, key moments, sentiment, changes requested, promises made by the agent.
4. It compares each request/promise with the policy data and records a **verdict**:
   - `MATCH` — the change applied is what the member agreed to.
   - `MISMATCH` — something different was applied.
   - `NOT_APPLIED` — requested or promised on a call, but the policy never changed.
   - `NO_CALL_EVIDENCE` — a phone change with no call that supports it.
5. The UI streams the answer live, shows the verdicts, and plays the call audio at each cited moment.

---

## Quick start

Requires Python 3.12 on Windows (commands below use `.venv\Scripts`).

```bash
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
copy .env.example .env
python scripts/build_db.py
.venv\Scripts\python -m uvicorn backend.main:app
```

Then open **http://127.0.0.1:8000/** (API docs: http://127.0.0.1:8000/docs).

`.env` settings:

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude API key (needed for the chatbot and call analysis) |
| `MOCK_CLAUDE=1` | Simulated Claude: rehearse the demo with no API key or cost |
| `CLAUDE_MODEL` | Optional model override (default `claude-opus-5`) |
| `DB_PATH` | Database file (default `data/cru.db`) |

---

## Toolkit

| Layer | Technology |
|---|---|
| Language | Python 3.12, JavaScript (ES modules) |
| Backend | FastAPI + Uvicorn |
| Database | SQLite (Python `sqlite3`) |
| AI | Claude API via the official `anthropic` Python SDK — model `claude-opus-5` |
| Speech-to-text | OpenAI Whisper `small.en`, run locally with `faster-whisper` (CPU) |
| Frontend | Plain HTML, CSS and JavaScript — no framework, no build step |
| Streaming | Server-Sent Events (SSE) |
| Demo audio | Synthetic call generated with ElevenLabs |

---

## Parts

### Database — `data/schema.sql` → `data/cru.db`

One SQL script creates the schema and the synthetic data; `scripts/build_db.py` rebuilds the database from it. Tables fall into three groups:

| Group | Tables | Used by |
|---|---|---|
| **Source data** — what the policy system and call recordings hold | `members`, `policies`, `policy_terms` (six-month terms), `drivers`, `vehicles`, `coverages` (what was in force on each date), `transactions` (every change: ADD / REMOVE / MODIFY, channel PHONE / APP / WEB), `coverage_catalog`, `rental_tiers`, `calls`, `call_segments` (transcript turn by turn, with speaker and start/end second) | Chatbot and UI |
| **AI output** — written by the app | `call_analysis` (cached analysis per call), `audit_findings` (verdicts) | Chatbot and UI |
| **Ground truth** — the correct answer for each call | `expected_call_events` | Evaluation only — the chatbot never reads it |

Views: `v_active_coverages` (coverages in force today), `v_change_history` (transactions with their term), `v_call_transcripts` (full transcript per call), `v_expected_cru_evidence` (evaluation only).

Rental reimbursement has four tiers (demo assumptions): **R30** Economy/Compact, **R40** Intermediate/Standard, **R50** Full-size sedan/Small SUV, **R60** Mid-size SUV/Minivan/Pickup — $30–60/day, max 30 days. Rental coverage is always described by vehicle class, never by car make or model.

### Speech-to-text — `scripts/transcribe_call.py`, `scripts/label_speakers.py`

- `transcribe_call.py` runs Whisper locally on an MP3 and saves text with word-level timestamps to `data/transcripts/<name>.json`. The model (~480 MB) downloads to `models/` on first run; after that it works offline.
- Whisper does not tell speakers apart, so `label_speakers.py` splits the transcript into **MEMBER** / **AGENT** turns using the word timestamps and the points where the speaker changes (marked by hand), and outputs the rows for `call_segments`.
- Transcription is done **before** the demo: 101 s of audio takes ~90 s on a 4-core laptop. The app reads the stored transcript.

### Claude connection — `backend/services/llm.py`

- Uses the official `anthropic` SDK (`AsyncAnthropic`) with model `claude-opus-5`.
- **Server-side fallback** (`fallbacks: "default"`): if the model declines a request, the API retries it on a recommended fallback model.
- **Prompt caching** on the chat requests to reduce cost and latency.
- **Structured outputs** (JSON schema) for call analysis, so results always have the same shape.
- `MOCK_CLAUDE=1` swaps in a simulated client (`mock_claude.py`) that follows the same review flow with scripted decisions; tools, database and UI run for real. Simulated results are tagged `mock-claude` and deleted when the server starts in real mode.

### Chatbot — `backend/chat/`

A streaming **tool-use loop** (`agent.py`): Claude decides which tool to call, the backend runs it, the result goes back to Claude, until it writes the final answer. Claude never writes SQL; it can only use these tools (`tools.py`), all with strict input schemas:

| Tool | What it returns |
|---|---|
| `find_policy` | Validates member + policy; member, current term, drivers, vehicles, coverages in force |
| `get_policy_changes` | Transactions, filterable by coverage, change type and dates |
| `get_coverages` | Coverages in force on a given date, or the full history |
| `list_calls` | All calls on the policy in a period — catches requests that never produced a transaction |
| `find_calls_for_change` | Calls within ±30 days of a transaction |
| `get_transcript` | Every turn of a call, with speaker and timestamp |
| `analyze_call` | Summary, key moments, sentiment, requested changes, agent promises (cached) |
| `record_audit_finding` | Stores a verdict, after checking the transaction, call and turn belong to the policy |

The system prompt (`prompts.py`) sets the review procedure and the answer format: verdicts first, every claim cited as `[Call N · m:ss]` or `[Txn N]`. The agent streams events to the browser: answer text, tool progress, and signals to refresh the side panels.

### Backend API — `backend/`

FastAPI app (`main.py`) that serves the UI and a REST API. All reads go through `queries.py` on a **read-only** database connection; only `call_analysis` and `audit_findings` are written.

| Endpoint | Purpose |
|---|---|
| `GET /api/policies/{policy}?member_number=` | Policy panel (validates the member) |
| `GET /api/policies/{policy}/changes · /coverages · /calls · /findings` | Policy data |
| `GET /api/calls/{id}` · `/transcript` · `/audio` | Call header + analysis, full transcript, MP3 |
| `POST /api/calls/{id}/analyze` | Run (or return cached) call analysis |
| `POST /api/chat` | Chat, streamed as Server-Sent Events |
| `POST /api/demo/reset` | Clear analyses, findings and conversations |

### Web UI — `frontend/`

One page, three panels:

- **Left — Policy:** "Start a review" form with example policies; then member and policy details, **findings** (color-coded verdicts), vehicles, coverages in force and change history.
- **Center — Chat:** the answer streams in with the assistant's steps ("Reading call transcript…"). Citations are clickable: `Call 7 · 1:15` jumps the audio to that moment; `Txn 8` highlights the change.
- **Right — Call evidence:** audio player with the turn being heard, summary, key moments, requested changes, agent promises, sentiment, and **Open full transcript**.

The top bar shows which model is answering (`claude-opus-5`, **Simulated Claude** or **Offline preview**) and a **Reset demo** button.

---

## Demo data

| Policy | Member | Vehicles | Calls | Case |
|---|---|---|---|---|
| `AUT-4471982-7101` (TX) | `00-4471-982` Daniel R. Ortiz | F-150 (replaced by Tacoma, 2024), CR-V | 5 scripted | All changes match; call 3 is only a question; on call 5 the member asks to remove rental, then lowers it to R40 instead |
| `AUT-5528310-7102` (VA) | `00-5528-310` Megan L. Brooks | Pacifica | 1 scripted | Rental removed as requested |
| `AUT-0123456-7103` (CO) | `123456` Fanny Rios | 2024 Volvo EX30 | **1 with real audio** (call 7, 2025-10-14) | **Main demo:** the member asks to remove rental (1:15) and the agent promises it (1:23), but no transaction exists and R40 is still active → `NOT_APPLIED` |

Call 7 audio is `data/audio/call_008.mp3` (synthetic, ~101 s); the other calls have written transcripts only.

---

## Demo modes

| Mode | How | Needs |
|---|---|---|
| **Live** | Server running, `ANTHROPIC_API_KEY` set | API key, internet |
| **Simulated** | Add `MOCK_CLAUDE=1` to `.env`, restart the server | Nothing — no API calls |
| **Offline preview** | Double-click `demo/cru-demo-offline.html` | Nothing — no server, database or internet |

The offline preview is the full UI in one file (audio included). It replays six recorded reviews — the three policies with *Rental reimbursement* or *All coverages*, from the form or the suggested questions. Rebuild it after UI or data changes: `.venv\Scripts\python scripts/build_offline_demo.py`.

`python scripts/demo_chat.py` chats with a running server from the terminal.

---

## Project structure

```
├── backend/
│   ├── main.py              FastAPI app, serves the UI
│   ├── config.py            .env settings
│   ├── db.py                read-only / write connections
│   ├── queries.py           all database reads
│   ├── api/                 REST endpoints (policies, calls, chat)
│   ├── chat/                agent loop, tools, system prompt
│   └── services/            Claude client, simulated Claude, call analysis, audit findings
├── frontend/                index.html, css/, js/ (chat, policy panel, call panel)
├── data/
│   ├── schema.sql           schema + synthetic data
│   ├── cru.db               built database
│   ├── audio/call_008.mp3   demo call recording
│   └── transcripts/         Whisper output for call_008
├── scripts/
│   ├── build_db.py          rebuild the database
│   ├── transcribe_call.py   speech-to-text
│   ├── label_speakers.py    MEMBER / AGENT turns
│   ├── build_offline_demo.py  build the offline preview
│   ├── demo_chat.py         terminal chat client
│   └── mp3_to_wav.ps1       MP3 → WAV with the Windows transcoder (no ffmpeg)
├── demo/cru-demo-offline.html
├── requirements.txt
└── .env.example
```

---

## Troubleshooting

- **Page stays blank / server stops responding (Windows):** clicking inside a Command Prompt window pauses the program ("QuickEdit mode"). Press **Esc** in the server window, or disable it: title bar → Properties → Options → uncheck *QuickEdit Mode*.
- **Whisper fails to load (`ctranslate2.dll` … not found):** install the Microsoft *Visual C++ Redistributable x64*, or copy a Microsoft-signed 64-bit `msvcp140.dll` into `.venv\Lib\site-packages\ctranslate2\`.
- **Downloads fail behind a corporate proxy (TLS inspection):** use a normal network for `pip install` and the first Whisper run, or make Python trust the Windows certificate store (`truststore`).

## Open questions for the business (Victoria Lara)

- Which coverage details the CRU reviews for each change.
- Whether the rental reimbursement tiers and vehicle classes match USAA's.
