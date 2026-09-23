# CRU Review Assistant — Hackathon TCS x USAA

## Business context
- Client: USAA, Property & Casualty (auto). Business contact: Victoria Lara.
- Today the CRU review is manual: an agent reviews 20+ policy terms, looks for coverage transactions (e.g. rental reimbursement: add / remove / modify) and listens to member calls spanning several years.
- Desired outcome (hackathon form): filter the policy down to the relevant transactions and review/summarize calls, surfacing the parts needed for the CRU review.
- Pain points flagged: manual effort, slow turnaround, customer experience. Impact: cost, productivity, customer experience.
- To confirm with Victoria: what CRU stands for exactly, which details of each coverage are reviewed, and whether the rental tiers match our assumptions.

## Rules
- Synthetic data only (organizers' instruction). No real member data.
- Goal: a working web app that can be demoed live.
- Two-person team.

## Solution plan
See `README.md` for the full status, workflow and work proposal.
1. Audio: `data/audio/call_008.mp3` is the only call recording the app will use (synthetic, ElevenLabs).
2. Transcription: local speech-to-text (Whisper) with timestamps → call segments table.
3. AI analysis (Claude): summary, highlights, sentiment, requested/promised changes per call.
4. Chatbot: given member number + policy number + criteria, finds policy changes, finds the calls around each change, transcribes/analyzes them, and audits "what was asked on the call" vs. "what was applied to the policy", citing date, call and timestamp.

## Database
- SQLite. Full script in `data/cru_hackathon_db.sql`; build with `sqlite3 data/cru.db < data/cru_hackathon_db.sql` (or Python `sqlite3.executescript`).
- The current schema uses Spanish names (`miembros`, `polizas`, `periodos`, `coberturas`, `transacciones`, `llamadas`, `segmentos`, `eventos_llamada`, ...). Planned: translate it to English (see README).
- Rental reimbursement: 4 tiers R30/R40/R50/R60 ($/day), max 30 days, each with a rental vehicle class and examples. Amounts and classes are ASSUMPTIONS for the demo.
- Public USAA info used: rental requires collision + comprehensive, does not cover maintenance, called "transportation expense" in some states; car replacement assistance pays 20% over actual cash value.

## Sample data
- Policy 1 (TX, Army, AUT-4471982-7101): F-150 (replaced by Tacoma in 2024), CR-V. 10 transactions, 6 scripted calls.
- Policy 2 (VA, Navy veteran, AUT-5528310-7102): Pacifica. 3 transactions, 1 scripted call.
- Demo trap cases (scripted calls, no audio):
  - Call 3: inquiry only, no change.
  - Call 5: asks to remove rental, changes their mind and downgrades to R40.
  - Call 6: the agent promises to add Rideshare Gap but there is NO transaction → CRU alert.
- `eventos_llamada` holds the "ground truth"; use it to evaluate what the AI extracts.

## Language
- All code, identifiers, UI text, prompts and docs in English.
- Transcripts and audio in English. Team chat may be in Spanish.
