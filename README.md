# CRU Review Assistant

Hackathon project — TCS x USAA (Property & Casualty, auto). A web app with an AI chatbot that audits policy changes against the evidence in recorded member calls.

> **Status:** database, call transcript, backend (FastAPI + chat agent) and web UI done; next: test against the live Claude API and rehearse the demo. This document captures everything decided so far so work can continue on another machine.

## Quick start

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt
cp .env.example .env            # then set ANTHROPIC_API_KEY
python scripts/build_db.py      # rebuilds data/cru.db from data/schema.sql
.venv/Scripts/python -m uvicorn backend.main:app --reload
```

Open the app at **http://127.0.0.1:8000/** (API docs at http://127.0.0.1:8000/docs). Everything except `/api/chat` and `/api/calls/{id}/analyze` works without an API key.

**Rehearse without an API key:** add `MOCK_CLAUDE=1` to `.env` and restart. Claude's answers are simulated (a scripted review flow; call analyses built from the ground truth), while the tools, database writes and UI events run for real. Use the web app as usual (the top bar shows **Simulated Claude**), or chat from the terminal with `python scripts/demo_chat.py`.

**Offline preview (to show the page, no setup):** open `demo/cru-demo-offline.html` by double-clicking it. It is the same web app in one file (2.3 MB, audio included) that replays six recorded reviews: the three example policies × *Rental reimbursement* / *All coverages*, started from the form or the suggested questions. No server, database, internet or API key. Rebuild it after UI or data changes with `.venv/Scripts/python scripts/build_offline_demo.py`. Remove the line to use the real API; simulated analyses and findings are deleted automatically when the server starts in real mode.

---

## 1. Business context

- **CRU:** Coverage Response Unit.
- **Client:** USAA, P&C auto. Business contact: Victoria Lara.
- **Today:** the CRU review is manual. A reviewer goes through 20+ policy terms, looks for coverage transactions (e.g. rental reimbursement added / removed / modified) and listens to years of member calls.
- **Desired outcome:** filter the policy to the relevant transactions and review/summarize the calls, surfacing only the parts needed for the CRU review.
- **Pain points:** manual effort, slow turnaround, customer experience. **Impact:** cost, productivity, customer experience.
- **Key risk the app addresses:** what is recorded in the policy tables may not match what the member actually asked for on the phone.
- **Rules:** synthetic data only (organizers' instruction); must be a working app demoable live; two-person team.
- **Open questions for Victoria:** which coverage details are reviewed; whether our rental tier assumptions are right.

## 2. What exists today

| Path | What it is |
|---|---|
| `data/schema.sql` | Full SQLite schema + synthetic seed data (English) |
| `scripts/build_db.py` | Rebuilds `data/cru.db` from `data/schema.sql` |
| `data/cru.db` | Database built from the script (identical content) |
| `data/audio/call_008.mp3` | **The only call recording the app will use.** Synthetic (ElevenLabs, voice "Elise"), ~100.9 s, 128 kbps, 44.1 kHz, contains a C2PA "AI-generated" manifest. Original file name: `ElevenLabs_2026-09-23T20_23_03_Elise – Warm, Natural and Engaging_pvc_sp100_s50_sb75_se0_b_m2.mp3` |
| `data/transcripts/call_008.json` | Raw Whisper output: segments + word timestamps |
| `data/transcripts/call_008.turns.json` | Transcript split into MEMBER / AGENT turns (loaded into `call_segments` as call 7) |
| `scripts/transcribe_call.py` | Local Whisper (faster-whisper `small.en`, CPU int8) → `data/transcripts/<name>.json` |
| `scripts/label_speakers.py` | Splits the Whisper transcript into speaker turns and prints the `call_segments` rows |
| `requirements.txt` | Python dependencies (currently only speech-to-text) |
| `scripts/mp3_to_wav.ps1` | Tested: converts MP3 → 16 kHz mono WAV with the native Windows transcoder (no ffmpeg) |
| `CLAUDE.md` | Project instructions for Claude Code |
| `.env.example` | Environment variables the app will need |

`call_008.mp3` is transcribed and registered as **call 7** (policy 3, Fanny Rios, 2025-10-14).

### Database summary

- **Source data:** `coverage_catalog` (12 rows), `rental_tiers` (4), `members` (3), `policies` (3), `policy_terms` (24 six-month terms), `drivers` (4), `vehicles` (5), `coverages` (32, date-ranged; rental limits come only from `rental_tiers`), `transactions` (12, with exact `old_/new_rental_tier` and `old_/new_deductible` plus display text), `calls` (7; `transcript_source` = `SCRIPTED` or `WHISPER`, `audio_file` only for real recordings), `call_segments` (47, `start_sec`/`end_sec`).
- **Ground truth (evaluation only, never exposed to the chatbot):** `expected_call_events` (11) and view `v_expected_cru_evidence`.
- **AI output (empty in the seed):** `call_analysis` (summary, highlights, sentiment, requested changes, agent promises per call) and `audit_findings` (verdict `MATCH/MISMATCH/NOT_APPLIED/NO_CALL_EVIDENCE` with quoted segment).
- **Chatbot views:** `v_active_coverages` (active coverages), `v_change_history` (transaction + policy term), `v_call_transcripts` (full transcript per call, one row per call: header fields + `full_text` with `[m:ss] SPEAKER: text` lines, built from `call_segments`).
- **Rental reimbursement tiers (demo assumptions):** R30 Economy/Compact, R40 Intermediate/Standard, R50 Full-size sedan/Small SUV, R60 Mid-size SUV/Minivan/Pickup; max 30 days.
- **Sample policies:**
  - Policy 1 — TX, Army, `AUT-4471982-7101`: F-150 (replaced by Tacoma in 2024), CR-V. 8 transactions, 5 scripted calls.
  - Policy 2 — VA, Navy veteran, `AUT-5528310-7102`: Pacifica. 3 transactions, 1 scripted call.
  - Policy 3 — CO, Air Force veteran, `AUT-0123456-7103`, member `123456` Fanny Rios: 2024 Volvo EX30 (VIN `YV4EF3ERG2174639K`) with rental R40. 1 transaction (new business), 1 call **with real audio** (call 7 = `call_008.mp3`, 2025-10-14, agent Sarah).
- **Demo cases:** call 3 inquiry only; call 5 asks to remove rental then downgrades to R40; **call 7 (live demo, real audio)** member asks to remove rental to save ~$15/month and the agent promises to process it, but **no transaction exists and rental R40 is still active** → CRU alert (`NOT_APPLIED`).
- `transactions.source_call_id` is only a hint: the audit finds calls by policy and date, as a real reviewer would.
- Call 7 transcript notes: the audio says a non-existent "Volvo CX30"; the turns use the real model **EX30** (see `CORRECTIONS` in `scripts/label_speakers.py`). The agent reads the last 11 VIN characters (`ERG2174639K`).

## 3. Planned user workflow

```
Reviewer (chat): "Review changes to rental reimbursement on policy AUT-4471982-7101, member #..."
  1. Validate member_number + policy_number
  2. Query the policy transactions matching the criteria (coverage, change type, date range)
  3. For each change → find the calls in the same policy term / ±N days;
     also list the policy's calls in the date range, to catch requests with NO transaction
  4. Transcribe the call MP3 (on demand, cached in the DB)
  5. Analyze the call: summary, highlights, sentiment (member & agent, overall and over time),
     what the member requested, what the agent promised
  6. Audit requested vs. applied → MATCH / MISMATCH / NOT_APPLIED / NO_CALL_EVIDENCE,
     with quotes and timestamps
```

## 4. Work proposal

**Language rule:** all code, identifiers, UI text, prompts and docs in English.

### Tech stack

| Layer | Choice | Why |
|---|---|---|
| Backend | Python 3.12 + FastAPI + uvicorn | Already installed on the dev machine |
| Database | SQLite via stdlib `sqlite3` | Zero setup |
| LLM | Claude API (`claude-opus-5`) — tool use, structured outputs, streaming | Chat agent, call analysis, audit |
| MP3 decode | Native Windows transcoder (`scripts/mp3_to_wav.ps1`) | Proven to work, no ffmpeg (could switch to ffmpeg/PyAV on a normal machine) |
| Speech-to-text | Local Whisper `small.en` via `faster-whisper` (CTranslate2, CPU int8) | Word timestamps, offline, no torch/ffmpeg (decodes MP3 itself) |
| Speaker labels | Claude assigns MEMBER / AGENT per turn | Whisper doesn't diarize |
| Frontend | No-build HTML + vanilla JS served by FastAPI, vendored libs | No npm needed → demo-safe (React + Vite is fine if npm works) |
| Chat streaming | Server-Sent Events | Live answer + status like "Transcribing call…" |

### Proposed project structure

```
├── README.md
├── CLAUDE.md
├── .env.example                  # ANTHROPIC_API_KEY, DB_PATH, CLAUDE_MODEL
├── requirements.txt
├── data/
│   ├── schema.sql                # English schema + seed
│   ├── cru.db                    # generated
│   └── audio/call_008.mp3
├── models/whisper-small.en/      # local STT model (git-ignored)
├── scripts/
│   ├── build_db.py               # schema.sql → cru.db
│   ├── transcribe_call.py        # local Whisper → data/transcripts/<name>.json
│   ├── label_speakers.py         # Whisper segments → MEMBER/AGENT turns
│   ├── demo_chat.py              # terminal chat client for /api/chat (SSE)
│   ├── build_offline_demo.py     # records mock reviews → demo/cru-demo-offline.html
│   └── mp3_to_wav.ps1
├── backend/
│   ├── main.py                   # FastAPI app (+ serves frontend/ when it exists)
│   ├── config.py                 # .env settings (DB_PATH, CLAUDE_MODEL)
│   ├── db.py                     # read-only connection for queries; write only for AI output
│   ├── queries.py                # all reads, shared by the REST API and the chat tools
│   ├── api/
│   │   ├── policies.py           # GET /api/policies/{number}?member_number=, /changes, /coverages, /calls, /findings
│   │   ├── calls.py              # GET /api/calls/{id}, /transcript, /audio; POST /analyze
│   │   └── chat.py               # POST /api/chat (SSE), POST /api/demo/reset
│   ├── services/
│   │   ├── llm.py                # AsyncAnthropic client, model, refusal fallback
│   │   ├── mock_claude.py        # simulated Claude for MOCK_CLAUDE=1
│   │   ├── call_analysis.py      # Claude structured output → call_analysis (cached)
│   │   └── audit.py              # validates + stores verdicts in audit_findings
│   └── chat/
│       ├── agent.py              # streaming tool-use loop → UI events
│       ├── tools.py              # 8 strict tools, status labels, UI events
│       └── prompts.py            # system prompt
└── frontend/                     # no build step, served by FastAPI at /
    ├── index.html
    ├── css/app.css
    └── js/
        ├── app.js                # chat: streamed answer, tool steps, citation chips
        ├── api.js                # fetch helpers + SSE reader for POST /api/chat
        ├── format.js             # escaping, times, small Markdown renderer with citations
        ├── policy-panel.js       # member, policy, findings, vehicles, coverages, change history
        └── call-panel.js         # audio + "now playing" turn, analysis, full-transcript dialog
```

### Chatbot tools

The model only reaches the DB through fixed tools (no free-form SQL) → reproducible answers and every result carries its source for citations.

| Tool | Purpose |
|---|---|
| `find_policy(member_number, policy_number)` | Validate that member and policy match; member, policy, current term, drivers, vehicles, coverages in force |
| `get_policy_changes(policy_number, coverage_code, change_type, date_from, date_to)` | Transactions with their policy term, channel, exact old/new rental tier and deductible |
| `get_coverages(policy_number, coverage_code, as_of)` | Coverages in force on a date (what the policy showed after a call), or the full history |
| `list_calls(policy_number, date_from, date_to)` | All calls in a period — needed for requests that were never applied (no transaction to start from, e.g. call 7) |
| `find_calls_for_change(transaction_id, window_days)` | Calls within ±N days of a change (default 30) |
| `get_transcript(call_id)` | Full transcript (turns with seq, speaker, `m:ss`) |
| `analyze_call(call_id)` | Summary, highlights, sentiment, requested changes (with final decision) and agent promises — Claude structured output, cached in `call_analysis` |
| `record_audit_finding(policy_number, verdict, coverage_code, transaction_id, call_id, segment_seq, requested, applied, explanation)` | Store a verdict (`MATCH / MISMATCH / NOT_APPLIED / NO_CALL_EVIDENCE`) in `audit_findings`; references are validated against the policy |

Tools use strict schemas (every field required, optional ones nullable). The model is `claude-opus-5` (override with `CLAUDE_MODEL`), with server-side refusal fallback (`fallbacks: "default"`) and prompt caching. Answers stream to the browser as SSE events: `session`, `text`, `tool` / `tool_done` (status line), `policy`, `call`, `finding` (update the side panels), `error`, `done` — see `backend/chat/agent.py`.

### How the chatbot uses the tables

Example request: *"Review the rental reimbursement changes on policy AUT-4471982-7101, member 00-4471-982."*

| Step | What it does | Tables |
|---|---|---|
| 1. Validate member and policy | Looks up member **00-4471-982** and confirms policy AUT-4471982-7101 belongs to them → Daniel R. Ortiz. | `members`, `policies` |
| 2. Find the changes | Filters the history by **`coverage_code = RENTAL`** → 4 changes (transactions 2, 3, 6 and 8), each with its six-month policy term. | `transactions`, `policy_terms` |
| 3. Find calls around each change | Looks for calls on the same policy within ±30 days of each change. E.g. the 2025-02-14 change → **call 5**. Call 3 also shows up, with no change. | `calls` |
| 4. Read what was said | Pulls the transcript turn by turn, with speaker and start/end second. | `call_segments` |
| 5. Analyze the call | The AI writes a summary, highlights and sentiment, and extracts what the member requested and what the agent promised. Cached so it is not repeated. | `call_analysis` |
| 6. Audit requested vs. applied | Compares *"Lower it to 40"* (1:10) with **`new_rental_tier = R40`** → `MATCH`. | `transactions`, `rental_tiers`, `audit_findings` |

Rules:
- `expected_call_events` and `v_expected_cru_evidence` hold the answers. No chatbot tool reads them; they are only used to measure whether the AI reached the same conclusion.
- Rental coverage is described by its vehicle class only (e.g. *Intermediate / Standard*), never by specific car makes or models.

### Database changes

- ~~Translate the schema to English~~ (done: `data/schema.sql`; enum values `NEW_BUSINESS/ADD/REMOVE/MODIFY`, `PHONE/APP/WEB`, `MEMBER/AGENT`, etc.)
- ~~Add `call_segments.end_sec`, `call_analysis` and `audit_findings`; separate AI output from the ground truth; structured transaction values; indexes~~ (done).
- Pending: register `call_008.mp3` (make `audio_file` optional for scripted calls and record whether a transcript is scripted or from Whisper).

### UI (single page)

- **Left — Policy Context:** "Start a review" form (member, policy, coverage; example policies), then member, policy, current term, **findings** (verdict pills), vehicles, coverages in force, change history filterable by coverage.
- **Center — Chat:** streamed answer with the assistant's steps ("Reading call transcript…"); citations rendered as chips (`Call 7 · 1:15` seeks the audio, `Txn 8` highlights the change).
- **Right — Call Evidence:** audio player, transcript with MEMBER/AGENT labels and timestamps (an **"Open full transcript"** button shows every turn of the call from `v_call_transcripts`; clicking a timestamp seeks the audio when there is a recording), summary, highlights, sentiment per speaker/over time, audit verdict card.

### Live demo strategy

- Transcribing `call_008.mp3` (101 s) took **88.6 s** on the dev laptop (4 CPU cores) — too slow to run live. Pre-transcribe before the demo (already done: `data/transcripts/`) and load the cached transcript; optionally show a live re-transcription only if the demo machine is faster.
- "Reset demo" button clears cached transcript/analysis to replay the full flow.
- 3–4 rehearsed questions.

## 5. Environment notes (from the hackathon machine)

- `pip` could not download from `files.pythonhosted.org` (corporate TLS inspection certificate); the `anthropic` SDK was **not** installed. `curl` works because it uses the Windows certificate store. On a normal network just `pip install -r requirements.txt`.
- Python's `certifi` bundle does not trust the corporate CA → Hugging Face downloads failed from Python. Fix without disabling verification: pass `ssl.create_default_context()` (loads the Windows store) to the HTTP client, or use `truststore`.
- No ffmpeg on the machine → `scripts/mp3_to_wav.ps1` was used instead.
- Whisper model: the download of `model.safetensors` (~967 MB) was interrupted; `models/` is git-ignored. Re-download with:
  `huggingface-cli download openai/whisper-small.en --local-dir models/whisper-small.en`

- **Speech-to-text setup (dev laptop):** `python -m venv .venv` then `.venv/Scripts/python -m pip install -r requirements.txt`. The model (~480 MB) downloads to `models/` on first run.
- `ctranslate2` needs the Microsoft Visual C++ runtime (`msvcp140.dll`). If it is not installed, either install the official *VC++ Redistributable x64*, or copy a Microsoft-signed 64-bit `msvcp140.dll` (e.g. from the Edge install folder) into `.venv/Lib/site-packages/ctranslate2/` (app-local, no admin needed). The VAD filter is disabled because `onnxruntime` needs the same runtime and the synthetic audio has no noise.

## 6. Next steps

1. ~~Install the app dependencies~~ (in `requirements.txt`). Get an Anthropic API key and put it in `.env`.
2. ~~Download the Whisper model~~ / ~~transcribe `call_008.mp3` and register it~~ (done: call 7, policy 3).
3. Replace the hand-marked speaker changes in `scripts/label_speakers.py` with Claude labeling in `call_analysis.py`.
4. ~~Translate the schema to English (`data/schema.sql`) + `scripts/build_db.py`.~~ Done.
5. ~~Backend services → chat agent + tools → frontend~~ (done; chat not yet run end-to-end against the live API).
6. Rehearse the demo.

### Decisions pending

- Keep the 6 scripted calls (no audio) as "transcript on file" history, or remove them? Recommendation: keep them.
