"""Shared Claude client and request defaults."""

import anthropic

from ..config import settings

# If a safety classifier declines a request, the API re-runs it server-side on
# the fallback model Anthropic recommends for that refusal category.
FALLBACK = {"betas": ["server-side-fallback-2026-07-01"], "fallbacks": "default"}

if settings.mock_claude:
    from .mock_claude import MOCK_MODEL, MockClaude
    client = MockClaude()
    MODEL = MOCK_MODEL
else:
    client = anthropic.AsyncAnthropic()
    MODEL = settings.model


class ClaudeRefusal(RuntimeError):
    """Every model in the fallback chain declined the request."""


class MissingCredentials(RuntimeError):
    pass


def require_credentials() -> None:
    """Fail with a clear message instead of the SDK's TypeError when no credentials are set."""
    if not (client.api_key or client.auth_token or client.credentials):
        raise MissingCredentials("Claude API credentials are not configured. "
                                 "Set ANTHROPIC_API_KEY in .env and restart the server.")
