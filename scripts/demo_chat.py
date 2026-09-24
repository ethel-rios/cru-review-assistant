"""Chat with the running backend from the terminal and watch the streamed events.

Usage:
  python scripts/demo_chat.py                      # asks the demo question, then lets you follow up
  python scripts/demo_chat.py "Review rental changes on policy AUT-4471982-7101, member 00-4471-982"

Needs the API running (uvicorn backend.main:app). With MOCK_CLAUDE=1 in .env
the answers are simulated and no API key is used. Only the standard library.
"""

import json
import os
import sys
import urllib.error
import urllib.request

API = os.getenv("CRU_API", "http://127.0.0.1:8000")
DEMO_QUESTION = "Review rental reimbursement changes on policy AUT-0123456-7103, member 123456."


def post_chat(message: str, session_id: str | None) -> str | None:
    body = json.dumps({"message": message, "session_id": session_id}).encode()
    request = urllib.request.Request(f"{API}/api/chat", data=body,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request) as response:
        for raw in response:
            line = raw.decode("utf-8").rstrip("\r\n")
            if not line.startswith("data: "):
                continue
            event = json.loads(line[6:])
            match event["type"]:
                case "session":
                    session_id = event["session_id"]
                case "text":
                    print(event["text"], end="", flush=True)
                case "tool":
                    print(f"\n  … {event['label']}  {json.dumps(event['input'], ensure_ascii=False)}", flush=True)
                case "tool_done" if not event["ok"]:
                    print(f"  ✗ {event['tool']}: {event['error']}")
                case "policy":
                    print(f"  ▸ [policy panel] {event['policy_number']}")
                case "call":
                    print(f"  ▸ [call panel] call {event['call_id']}")
                case "finding":
                    f = event["finding"]
                    where = f" [Call {f['call_id']} · turn {f['segment_seq']}]" if f["call_id"] else ""
                    print(f"  ▸ [finding] {f['verdict']} · {f['coverage_code']}{where}")
                case "error":
                    print(f"\n  ERROR: {event['message']}")
                case "done":
                    print("\n")
    return session_id


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    try:
        health = json.load(urllib.request.urlopen(f"{API}/api/health"))
    except urllib.error.URLError:
        sys.exit("The API is not running. Start it with:  .venv/Scripts/python -m uvicorn backend.main:app")
    print(f"Connected · model: {health['model']}\n")

    message = " ".join(sys.argv[1:]) or DEMO_QUESTION
    session_id = None
    while message:
        print(f"> {message}\n")
        session_id = post_chat(message, session_id)
        message = input("Follow-up (Enter to quit): ").strip()


if __name__ == "__main__":
    main()
