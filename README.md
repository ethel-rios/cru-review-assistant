# CRU Review Assistant

Hackathon project — TCS x USAA (Property & Casualty, auto). A web app with an AI chatbot that audits policy changes against the evidence in recorded member calls.

> **Status:** planning complete, no application code yet. This document captures everything decided so far so work can continue on another machine.

---

## 1. Business context

- **Client:** USAA, P&C auto. Business contact: Victoria Lara.
- **Today:** the CRU review is manual. A reviewer goes through 20+ policy terms, looks for coverage transactions (e.g. rental reimbursement added / removed / modified) and listens to years of member calls.
- **Desired outcome:** filter the policy to the relevant transactions and review/summarize the calls, surfacing only the parts needed for the CRU review.
- **Pain points:** manual effort, slow turnaround, customer experience. **Impact:** cost, productivity, customer experience.
- **Key risk the app addresses:** what is recorded in the policy tables may not match what the member actually asked for on the phone.
- **Rules:** synthetic data only (organizers' instruction); must be a working app demoable live; two-person team.
- **Open questions for Victoria:** what CRU stands for exactly; which coverage details are reviewed; whether our rental tier assumptions are right.

## 2. What exists today

| Path | What it is |
|---|---|
| `data/cru_hackathon_db.sql` | Full SQLite schema + synthetic seed data (currently Spanish identifiers) |
| `data/cru.db` | Database built from the script (identical content) |
| `data/audio/call_008.mp3` | **The only call recording the app will use.** Synthetic (ElevenLabs, voice "Elise"), ~100.9 s, 128 kbps, 44.1 kHz, contains a C2PA "AI-generated" manifest. Original file name: `ElevenLabs_2026-09-23T20_23_03_Elise – Warm, Natural and Engaging_pvc_sp100_s50_sb75_se0_b_m2.mp3` |
| `scripts/mp3_to_wav.ps1` | Tested: converts MP3 → 16 kHz mono WAV with the native Windows transcoder (no ffmpeg) |
| `CLAUDE.md` | Project instructions for Claude Code |
| `.env.example` | Environment variables the app will need |

**Not done yet:** the MP3 has **not** been transcribed and has **not** been registered in the database (we still need to confirm which policy / date it belongs to).

### Database summary (current, Spanish names)

- **Tables (12):** `catalogo_coberturas` (12 rows), `niveles_renta` (4), `miembros` (2), `polizas` (2), `periodos` (18 six-month terms), `conductores` (3), `vehiculos` (4), `coberturas` (26, date-ranged + `detalles` JSON), `transacciones` (13), `llamadas` (7), `segmentos` (41), `eventos_llamada` (10).
- **Views:** `v_coberturas_vigentes` (active coverages), `v_historial` (transaction + policy term), `v_evidencia_cru` (said on call vs. applied to policy).
- **Rental reimbursement tiers (demo assumptions):** R30 Economy/Compact, R40 Intermediate/Standard, R50 Full-size sedan/Small SUV, R60 Mid-size SUV/Minivan/Pickup; max 30 days.
- **Sample policies:**
  - Policy 1 — TX, Army, `AUT-4471982-7101`: F-150 (replaced by Tacoma in 2024), CR-V. 10 transactions, 6 scripted calls.
  - Policy 2 — VA, Navy veteran, `AUT-5528310-7102`: Pacifica. 3 transactions, 1 scripted call.
- **Demo trap cases (scripted transcripts, no audio):** call 3 inquiry only; call 5 asks to remove rental then downgrades to R40; call 6 agent promises Rideshare Gap but no transaction exists → CRU alert.
- `eventos_llamada` is the ground truth for evaluating AI extraction.
- **Data issues found:** `llamadas.resumen` / `highlights` are empty (to be filled by AI); `archivo_audio` points to `audio/call_00X.mp3` files that don't exist; segment timestamps don't match `duracion_seg`.

## 3. Planned user workflow

```
Reviewer (chat): "Review changes to rental reimbursement on policy AUT-4471982-7101, member #..."
  1. Validate member_number + policy_number
  2. Query the policy transactions matching the criteria (coverage, change type, date range)
  3. For each change → find the calls in the same policy term / ±N days
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
| Speech-to-text | Local Whisper `openai/whisper-small.en` via `transformers` + `torch` | Timestamps, works offline once the model is downloaded |
| Speaker labels | Claude assigns MEMBER / AGENT per turn | Whisper doesn't diarize |
| Frontend | No-build HTML + vanilla JS served by FastAPI, vendored libs | No npm needed → demo-safe (React + Vite is fine if npm works) |
| Chat streaming | Server-Sent Events | Live answer + status like "Transcribing call…" |

### Proposed project structure

```
├── README.md
├── CLAUDE.md
├── .env.example                  # ANTHROPIC_API_KEY, DB_PATH, AUDIO_DIR, WHISPER_MODEL_DIR
├── requirements.txt
├── data/
│   ├── schema.sql                # English schema + seed (translated from cru_hackathon_db.sql)
│   ├── cru.db                    # generated
│   └── audio/call_008.mp3
├── models/whisper-small.en/      # local STT model (git-ignored)
├── scripts/
│   ├── build_db.py               # schema.sql → cru.db
│   ├── register_call.py          # insert call_008.mp3 as a call record
│   └── mp3_to_wav.ps1
├── backend/
│   ├── main.py                   # FastAPI app, static + audio mounts
│   ├── config.py
│   ├── db.py                     # read-only connection for chat tools
│   ├── api/
│   │   ├── policies.py           # GET /api/policies/{number}, /changes
│   │   ├── calls.py              # GET /api/calls/{id}, /audio; POST /transcribe
│   │   └── chat.py               # POST /api/chat (SSE)
│   ├── services/
│   │   ├── audio.py              # MP3 → 16 kHz WAV
│   │   ├── transcription.py      # Whisper → timestamped segments (cached)
│   │   ├── call_analysis.py      # Claude: speakers, summary, highlights, sentiment
│   │   └── audit.py              # requested vs. applied → verdict
│   └── chat/
│       ├── agent.py              # tool-use loop + streaming
│       ├── tools.py
│       └── prompts.py
└── frontend/
    ├── index.html
    ├── css/app.css
    ├── js/ app.js, api.js, chat.js, evidence-panel.js, audio-player.js
    └── vendor/
```

### Chatbot tools

The model only reaches the DB through fixed tools (no free-form SQL) → reproducible answers and every result carries its source for citations.

| Tool | Purpose |
|---|---|
| `find_policy(member_number, policy_number)` | Validate that member and policy match |
| `get_policy_changes(policy_number, coverage_code?, change_type?, date_from?, date_to?)` | Transactions with their policy term |
| `find_calls_for_change(transaction_id, window_days=30)` | Calls around the change |
| `transcribe_call(call_id)` | Whisper transcription (or cached) |
| `analyze_call(call_id)` | Summary, highlights, sentiment, requested/promised changes |
| `audit_change(transaction_id, call_id)` | Verdict with quotes + timestamps |

### Database changes

- Translate the schema to English: `members`, `policies`, `policy_terms`, `drivers`, `vehicles`, `coverages`, `coverage_catalog`, `rental_tiers`, `transactions`, `calls`, `call_segments`, `call_events`; enum values `NEW_BUSINESS/ADD/REMOVE/MODIFY`, `PHONE/APP/WEB`, etc.
- Add `call_segments.end_sec`, a `call_analysis` table (summary, highlights JSON, sentiment JSON) and an `audit_findings` table.
- Keep AI output separate from `call_events` (ground truth) so it can be evaluated.

### UI (single page)

- **Left — Policy Context:** member, policy, terms, change timeline filterable by coverage.
- **Center — Chat:** citations rendered as chips (`Call 8 · 0:42`) that seek the audio player.
- **Right — Call Evidence:** audio player, transcript with MEMBER/AGENT labels and timestamps, summary, highlights, sentiment per speaker/over time, audit verdict card.

### Live demo strategy

- Preload Whisper at server start; transcribing ~100 s of audio on CPU takes ~20–40 s. Transcribe live once, then cache.
- "Reset demo" button clears cached transcript/analysis to replay the full flow.
- 3–4 rehearsed questions.

## 5. Environment notes (from the hackathon machine)

- `pip` could not download from `files.pythonhosted.org` (corporate TLS inspection certificate); the `anthropic` SDK was **not** installed. `curl` works because it uses the Windows certificate store. On a normal network just `pip install -r requirements.txt`.
- Python's `certifi` bundle does not trust the corporate CA → Hugging Face downloads failed from Python. Fix without disabling verification: pass `ssl.create_default_context()` (loads the Windows store) to the HTTP client, or use `truststore`.
- No ffmpeg on the machine → `scripts/mp3_to_wav.ps1` was used instead.
- Whisper model: the download of `model.safetensors` (~967 MB) was interrupted; `models/` is git-ignored. Re-download with:
  `huggingface-cli download openai/whisper-small.en --local-dir models/whisper-small.en`

## 6. Next steps

1. Install dependencies (`fastapi`, `uvicorn`, `anthropic`, `transformers`, `torch`, `scipy`) and get an Anthropic API key.
2. Download the Whisper model.
3. Transcribe `call_008.mp3`, decide which policy/date/agent it belongs to, and register it in the DB.
4. Translate the schema to English (`data/schema.sql`) + `scripts/build_db.py`.
5. Backend services → chat agent + tools → frontend.
6. Rehearse the demo.

### Decisions pending

- Keep the 7 scripted calls (no audio) as "transcript on file" history, or remove them? Recommendation: keep them.
- Which policy/date does `call_008.mp3` belong to? (determine after transcription)
