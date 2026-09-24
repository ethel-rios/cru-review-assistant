"""Chat agent: a streaming tool-use loop that yields UI events.

Events (sent to the browser as Server-Sent Events):
  session   {session_id}                     first event of every request
  text      {text}                           answer text, as it streams
  tool      {tool, label, input}             a tool started (status line)
  tool_done {tool, ok, error?}               a tool finished
  policy    {policy_number}                  load the policy panel
  call      {call_id}                        load the call evidence panel
  finding   {finding}                        a new audit verdict
  error     {message}
  done      {}

Conversations live in memory, keyed by session id (enough for the demo).
The history is append-only and keeps full content blocks (thinking, tool use)
so every turn can be sent back to the API unchanged.
"""

import logging
import uuid
from collections.abc import AsyncIterator

import anthropic

from ..services.llm import FALLBACK, MODEL, MissingCredentials, client, require_credentials
from . import tools
from .prompts import system_prompt

MAX_STEPS = 25
SESSIONS: dict[str, list] = {}
log = logging.getLogger(__name__)


def new_session() -> str:
    session_id = uuid.uuid4().hex
    SESSIONS[session_id] = []
    return session_id


def _answer_pending_tools(messages: list) -> None:
    """If the last turn asked for tools that never got results (the browser
    disconnected mid-answer), answer them so the history stays valid."""
    if not messages or messages[-1]["role"] != "assistant":
        return
    pending = [b.id for b in messages[-1]["content"] if b.type == "tool_use"]
    if pending:
        messages.append({"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": i, "is_error": True, "content": "Interrupted."}
            for i in pending]})


async def chat(session_id: str, user_text: str) -> AsyncIterator[dict]:
    messages = SESSIONS.setdefault(session_id, [])
    _answer_pending_tools(messages)
    messages.append({"role": "user", "content": user_text})
    yield {"type": "session", "session_id": session_id}

    try:
        require_credentials()
        for _ in range(MAX_STEPS):
            async with client.beta.messages.stream(
                model=MODEL,
                max_tokens=64000,
                system=system_prompt(),
                tools=tools.TOOLS,
                messages=messages,
                cache_control={"type": "ephemeral"},
                **FALLBACK,
            ) as stream:
                async for event in stream:
                    if event.type == "text":
                        yield {"type": "text", "text": event.text}
                response = await stream.get_final_message()
            messages.append({"role": "assistant", "content": response.content})

            if response.stop_reason == "refusal":
                yield {"type": "error", "message": "Claude declined this request."}
                return
            tool_uses = [b for b in response.content if b.type == "tool_use"]
            if not tool_uses:
                if response.stop_reason == "max_tokens":
                    yield {"type": "error", "message": "The answer was cut off (max_tokens)."}
                yield {"type": "done"}
                return

            results = []
            for block in tool_uses:
                if response.stop_reason == "max_tokens":
                    # A tool call cut off mid-input: answer it so the history stays valid.
                    results.append({"type": "tool_result", "tool_use_id": block.id, "is_error": True,
                                    "content": "Tool input was truncated; call the tool again."})
                    continue
                yield {"type": "tool", "tool": block.name, "label": tools.LABELS.get(block.name, block.name),
                       "input": block.input}
                try:
                    result = await tools.run_tool(block.name, block.input)
                except Exception as e:  # any tool failure goes back to Claude as an error result
                    if not isinstance(e, tools.ToolError):
                        log.exception("tool %s failed", block.name)
                    yield {"type": "tool_done", "tool": block.name, "ok": False, "error": str(e)}
                    results.append({"type": "tool_result", "tool_use_id": block.id,
                                    "is_error": True, "content": str(e)})
                    continue
                yield {"type": "tool_done", "tool": block.name, "ok": True}
                if extra := tools.ui_event(block.name, block.input, result):
                    yield extra
                results.append({"type": "tool_result", "tool_use_id": block.id,
                                "content": tools.to_json(result)})
            messages.append({"role": "user", "content": results})

        yield {"type": "error", "message": f"Stopped after {MAX_STEPS} steps without a final answer."}
    except MissingCredentials as e:
        yield {"type": "error", "message": str(e)}
    except anthropic.AuthenticationError:
        yield {"type": "error", "message": "Claude API credentials are missing or invalid. "
                                           "Set ANTHROPIC_API_KEY in .env and restart the server."}
    except anthropic.RateLimitError:
        yield {"type": "error", "message": "Claude API rate limit reached. Try again in a minute."}
    except anthropic.APIStatusError as e:
        yield {"type": "error", "message": f"Claude API error {e.status_code}: {e.message}"}
    except anthropic.APIConnectionError:
        yield {"type": "error", "message": "Could not reach the Claude API. Check the network."}
