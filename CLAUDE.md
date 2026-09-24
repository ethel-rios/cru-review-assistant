# CRU Review Assistant — Hackathon TCS x USAA

## Business context
- CRU = Coverage Response Unit.
- Client: USAA, Property & Casualty (auto). Business contact: Victoria Lara.
- Today the CRU review is manual: an agent reviews 20+ policy terms, looks for coverage transactions (e.g. rental reimbursement: add / remove / modify) and listens to member calls spanning several years.
- Desired outcome (hackathon form): filter the policy down to the relevant transactions and review/summarize calls, surfacing the parts needed for the CRU review.
- Pain points flagged: manual effort, slow turnaround, customer experience. Impact: cost, productivity, customer experience.
- To confirm with Victoria: which details of each coverage are reviewed, and whether the rental tiers match our assumptions.

## Rules
- Synthetic data only (organizers' instruction). No real member data.
- Goal: a working web app that can be demoed live.
- Two-person team.

## Solution plan
See `README.md` for how the app works, the toolkit and the demo modes.
1. Audio: `data/audio/call_008.mp3` is the only call recording the app will use (synthetic, ElevenLabs).
2. Transcription: local Whisper (`faster-whisper`, `small.en`, CPU) with word timestamps → `scripts/transcribe_call.py`; speaker turns (MEMBER/AGENT) → `scripts/label_speakers.py` → `call_segments`. Pre-transcribed: `data/transcripts/`. Run with `.venv/Scripts/python`.
3. AI analysis (Claude): summary, highlights, sentiment, requested/promised changes per call.
4. Chatbot: given member number + policy number + criteria, finds policy changes, finds the calls around each change (and lists the policy's calls in the period, to catch requests with no transaction), transcribes/analyzes them, and audits "what was asked on the call" vs. "what was applied to the policy", citing date, call and timestamp.

## Backend
- FastAPI app in `backend/` (run: `.venv/Scripts/python -m uvicorn backend.main:app --reload`). Reads go through `backend/queries.py` on a read-only connection; only `call_analysis` and `audit_findings` are written.
- Chat agent (`backend/chat/`): manual streaming tool-use loop with the Anthropic SDK (`AsyncAnthropic`, `client.beta.messages.stream`), model `claude-opus-5`, `fallbacks: "default"`, prompt caching, 8 strict tools. No free-form SQL, no access to the ground truth.

## Database
- SQLite. Full script in `data/schema.sql`; build with `python scripts/build_db.py` (or `sqlite3 data/cru.db < data/schema.sql`).
- Schema and seed data are in English: `members`, `policies`, `policy_terms`, `drivers`, `vehicles`, `coverage_catalog`, `rental_tiers`, `coverages`, `transactions`, `calls`, `call_segments`; ground truth `expected_call_events`; AI output `call_analysis`, `audit_findings`.
- Full call transcripts: view `v_call_transcripts` (one row per call, built from `call_segments`) — used for the UI "Open full transcript" option.
- Rental reimbursement: 4 tiers R30/R40/R50/R60 ($/day), max 30 days, each with a rental vehicle class. Amounts and classes are ASSUMPTIONS for the demo.
- When describing rental coverage, the chatbot answers with the vehicle class only (e.g. "Intermediate / Standard"), never specific car makes or models.
- Public USAA info used: rental requires collision + comprehensive, does not cover maintenance, called "transportation expense" in some states; car replacement assistance pays 20% over actual cash value.

## Sample data
- Policy 1 (TX, Army, AUT-4471982-7101): F-150 (replaced by Tacoma in 2024), CR-V. 8 transactions, 5 scripted calls.
- Policy 2 (VA, Navy veteran, AUT-5528310-7102): Pacifica. 3 transactions, 1 scripted call.
- Policy 3 (CO, Air Force veteran, AUT-0123456-7103, member 123456 Fanny Rios): 2024 Volvo EX30, rental R40. Call 7 = the real audio `call_008.mp3` (2025-10-14, agent Sarah).
- Demo cases:
  - Call 3: inquiry only, no change.
  - Call 5: asks to remove rental, changes their mind and downgrades to R40.
  - Call 7 (live demo, real audio): member asks to remove rental; agent promises to process it; NO transaction, rental R40 still active → CRU alert (NOT_APPLIED).
- `expected_call_events` / `v_expected_cru_evidence` hold the "ground truth": use them only to evaluate what the AI extracts, never expose them to the chatbot tools.
- `transactions.source_call_id` is only a hint; the chatbot finds calls by policy and date.

## Frontend and demo modes
- `frontend/`: no-build HTML/CSS/JS served by FastAPI at `/` (policy panel, streamed chat with citation chips, call evidence panel).
- `MOCK_CLAUDE=1` in `.env` → simulated Claude (`backend/services/mock_claude.py`); results tagged `mock-claude`, purged on real-mode startup.
- Offline preview: `demo/cru-demo-offline.html` (single file, replays 6 recorded reviews). Rebuild with `.venv/Scripts/python scripts/build_offline_demo.py` after UI or data changes.

## Current status and next steps
- Working branch: `database-setup` (pushed, not merged into `main`).
- Chat not yet verified end-to-end against the live Claude API (call analysis for call 7 did run live once).
- Next: run the live review for all three policies, replace the hand-marked speaker changes in `scripts/label_speakers.py` with Claude labeling, rehearse the demo, merge to `main`.
- Consider removing `data/cru.db` from git (it is generated, and using the app writes AI output into it).

## Decisions — do not revert
- Scripted call 6 (Rideshare Gap promise) and its transactions were removed on purpose; call 7 is the NOT_APPLIED case.
- Call 7 audio says "Volvo CX30" (not a real model); transcript turns use **EX30** (`CORRECTIONS` in `label_speakers.py`). The DB VIN `YV4EF3ERG2174639K` ends with the 11 characters the agent reads aloud.
- Scripted transcripts mention vehicle classes only, no rental car makes/models.
- Transaction ids are global across policies (Fanny's only transaction is #12); that is intended.
- Do not commit the working copy of `data/cru.db` after using the app (it contains AI output); restore it with `git checkout -- data/cru.db` or rebuild with `scripts/build_db.py`.

## Setting up on a new machine
- Not in git: `.venv/`, `.env` (API key), `models/` (Whisper, ~480 MB, downloads on first transcription). Recreate with `python -m venv .venv`, `.venv/Scripts/python -m pip install -r requirements.txt`, `copy .env.example .env`.
- Whisper (`ctranslate2`) needs `msvcp140.dll`: install the VC++ Redistributable x64 or copy a Microsoft-signed 64-bit copy into `.venv/Lib/site-packages/ctranslate2/`. The VAD filter is off because `onnxruntime` needs the same runtime.
- Windows Command Prompt "QuickEdit" pauses the server when the window is clicked (page loads blank) — press Esc or disable QuickEdit.

## Working with the user
- The user writes in Spanish; answer in Spanish. Code, identifiers, UI text, prompts and docs stay in English.
- Commit and push only when asked. Commit as `ethel-rios` with `git -c user.name=... -c user.email=...` (no global git identity is configured).
- Never ask the user to paste secrets in chat; the API key lives only in `.env`.

## Language
- All code, identifiers, UI text, prompts and docs in English.
- Transcripts and audio in English. Team chat may be in Spanish.
