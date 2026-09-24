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
See `README.md` for the full status, workflow and work proposal.
1. Audio: `data/audio/call_008.mp3` is the only call recording the app will use (synthetic, ElevenLabs).
2. Transcription: local Whisper (`faster-whisper`, `small.en`, CPU) with word timestamps → `scripts/transcribe_call.py`; speaker turns (MEMBER/AGENT) → `scripts/label_speakers.py` → `call_segments`. Pre-transcribed: `data/transcripts/`. Run with `.venv/Scripts/python`.
3. AI analysis (Claude): summary, highlights, sentiment, requested/promised changes per call.
4. Chatbot: given member number + policy number + criteria, finds policy changes, finds the calls around each change (and lists the policy's calls in the period, to catch requests with no transaction), transcribes/analyzes them, and audits "what was asked on the call" vs. "what was applied to the policy", citing date, call and timestamp.

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

## Language
- All code, identifiers, UI text, prompts and docs in English.
- Transcripts and audio in English. Team chat may be in Spanish.
