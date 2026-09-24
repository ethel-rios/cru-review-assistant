"""Build demo/cru-demo-offline.html: the web app as one self-contained file that
replays recorded reviews (simulated Claude). Open it by double-clicking - no
server, database, internet or API key needed. Rebuild after changing the
frontend or the data:

    .venv/Scripts/python scripts/build_offline_demo.py [--artifact PATH]

--artifact also writes a copy without <html>/<head>/<body> wrappers, for
publishing as a claude.ai Artifact (the host adds them).
"""

import asyncio
import base64
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend"
OUT = ROOT / "demo" / "cru-demo-offline.html"
STATIC_API = Path(__file__).resolve().parent / "offline_demo" / "static-api.js"

# (member, policy) x scope, phrased exactly like the review form and the suggestions
EXAMPLES = [("123456", "AUT-0123456-7103"), ("00-4471-982", "AUT-4471982-7101"),
            ("00-5528-310", "AUT-5528310-7102")]
SCOPES = ["rental reimbursement", "all"]
MODULES = ["format", "api", "policy-panel", "call-panel", "app"]  # dependency order

# Record against a throwaway copy of the database, with simulated Claude.
TMP_DB = Path(tempfile.mkdtemp()) / "cru.db"
shutil.copy(ROOT / "data" / "cru.db", TMP_DB)
os.environ["DB_PATH"] = str(TMP_DB)
os.environ["MOCK_CLAUDE"] = "1"
sys.path.insert(0, str(ROOT))
from backend import queries  # noqa: E402  (imported after the environment is set)
from backend.chat import agent  # noqa: E402


async def record(question: str) -> list[dict]:
    with sqlite3.connect(TMP_DB) as conn:
        conn.execute("DELETE FROM audit_findings")  # each review starts with no findings
    return [event async for event in agent.chat(agent.new_session(), question)]


def api_snapshot(conversations: list[dict]) -> dict:
    """The GET responses the page asks for while replaying the conversations."""
    get = {"/api/health": {"ok": True, "model": "mock-claude", "offline": True}}
    for convo in conversations:
        member = next(e["input"]["member_number"] for e in convo["events"]
                      if e["type"] == "tool" and e["tool"] == "find_policy")
        for event in convo["events"]:
            if event["type"] == "policy":
                policy = event["policy_number"]
                get[f"/api/policies/{policy}?member_number={member}"] = queries.find_policy(member, policy)
                get[f"/api/policies/{policy}/changes"] = queries.get_policy_changes(policy)
            elif event["type"] == "call":
                call_id = event["call_id"]
                get[f"/api/calls/{call_id}"] = {**queries.get_call(call_id),
                                                "analysis": queries.get_call_analysis(call_id)}
                get[f"/api/calls/{call_id}/transcript"] = queries.get_transcript(call_id)
    return get


def audio_data(get: dict) -> dict:
    audio = {}
    for url, body in get.items():
        if re.fullmatch(r"/api/calls/\d+", url) and body["has_audio"]:
            path = ROOT / "data" / queries.audio_path(body["call_id"])
            audio[body["call_id"]] = "data:audio/mpeg;base64," + base64.b64encode(path.read_bytes()).decode()
    return audio


def module_var(name: str) -> str:
    return "__" + name.replace("-", "_")


def bundle_js() -> str:
    """Turn the ES modules into one classic script (file:// pages cannot load modules)."""
    parts = []
    for name in MODULES:
        path = STATIC_API if name == "api" else FRONTEND / "js" / f"{name}.js"
        src = path.read_text(encoding="utf-8")
        exports = re.findall(r"^export (?:async )?(?:function|const|let) (\w+)", src, re.M)
        src = re.sub(r"^export ", "", src, flags=re.M)
        src = re.sub(r'^import \{([^}]+)\} from "\./([\w-]+)\.js";$',
                     lambda m: f"const {{{m.group(1)}}} = {module_var(m.group(2))};", src, flags=re.M)
        assert not re.search(r"^import ", src, re.M), f"unbundled import in {name}"
        parts.append(f"const {module_var(name)} = (() => {{\n{src}\nreturn {{ {', '.join(exports)} }};\n}})();")
    return '"use strict";\n' + "\n\n".join(parts)


def build_html(data: dict) -> str:
    html = (FRONTEND / "index.html").read_text(encoding="utf-8")
    css = (FRONTEND / "css" / "app.css").read_text(encoding="utf-8")
    link, module = '<link rel="stylesheet" href="css/app.css">', '  <script type="module" src="js/app.js"></script>\n'
    assert link in html and module in html
    html = html.replace(link, f"<style>\n{css}</style>").replace(module, "")
    data_js = "window.CRU_DEMO_DATA = " + json.dumps(data, ensure_ascii=False).replace("</", "<\\/") + ";"
    return html.replace("</body>", f"<script>\n{data_js}\n</script>\n<script>\n{bundle_js()}\n</script>\n</body>")


def artifact_body(html: str) -> str:
    head = re.search(r"<head>(.*)</head>", html, re.S).group(1)
    body = re.search(r"<body>(.*)</body>", html, re.S).group(1)
    return re.sub(r"\s*<meta [^>]*>", "", head).strip() + "\n" + body.strip() + "\n"


async def main() -> None:
    conversations = []
    for member, policy in EXAMPLES:
        for scope in SCOPES:
            question = f"Review {scope} changes on policy {policy}, member {member}."
            events = await record(question)
            conversations.append({"question": question, "events": events})
            verdicts = [e["finding"]["verdict"] for e in events if e["type"] == "finding"]
            print(f"recorded  {question}  ->  {verdicts or 'no findings'}")
    get = api_snapshot(conversations)
    data = {"get": get, "conversations": conversations, "audio": audio_data(get)}

    html = build_html(data)
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size / 1e6:.1f} MB)")
    if "--artifact" in sys.argv:
        target = Path(sys.argv[sys.argv.index("--artifact") + 1])
        target.write_text(artifact_body(html), encoding="utf-8")
        print(f"wrote {target}")


if __name__ == "__main__":
    asyncio.run(main())
