"""Summarize a diarized transcript into meeting notes via Strands Agents on Bedrock.

Authentication: the Bedrock call uses a long-lived Bedrock API key (bearer
token) pulled from the macOS Keychain, not the AWS SSO / IAM session that
handles S3 and Transcribe. boto3 picks the bearer token up from the
AWS_BEARER_TOKEN_BEDROCK environment variable and applies it only to the
Bedrock clients — all other clients keep using the normal credential chain.

This lets the summarize step succeed even when the short-lived session
credentials that did the upload/Transcribe work have since expired. The
Keychain entry can be created with:

    security add-generic-password -U -a meetingrec \\
        -s meetingrec-bedrock -w <your-bedrock-api-key>
"""
from __future__ import annotations

import logging
import os

from .keychain import DEFAULT_SERVICE, KeychainError, get_password

log = logging.getLogger(__name__)

DEFAULT_MODEL_ID = "global.anthropic.claude-opus-4-7"

SYSTEM_PROMPT = """You are a careful meeting-notes assistant. You will receive a
diarized transcript of a meeting. The participant labeled "You" is the person who
recorded the meeting; other speakers ("Speaker A", "Speaker B", …) are the remote
participants and their identities are not known.

Produce clean, concise meeting notes as a Markdown document.

The very first line of your reply must be:

TITLE: <a specific 4-10 word title describing what this meeting was about>

Base the title on the actual content (e.g. "Q3 Launch Timeline Review with Vendor",
not "Meeting Notes" or "Zoom Call"). Do not use Markdown formatting, quotes, or
the characters / \\ : in the title. After that line, output the notes with these
sections (omit any section that has no content — don't invent):

# Meeting notes

## Summary
Two or three sentences capturing what the meeting was about and what was decided.

## Key discussion points
Bulleted. One bullet per topic. Keep each bullet short; don't restate the whole
transcript.

## Decisions
Bulleted. Only things that were actually decided, not discussed.

## Action items
Bulleted, in the form `- [ ] <owner>: <action> (due: <date if stated, else "not specified">)`.
Use "You" for the recorder; use "Speaker A/B/…" if the owner is a remote participant
whose name wasn't given. If an action item has no clear owner, use "Unassigned".

## Open questions
Bulleted. Things that were raised but not resolved.

Rules:
- Do not invent names, dates, numbers, or commitments. If something is ambiguous,
  say so or leave it out.
- Prefer the speakers' own phrasing for decisions and commitments.
- Ignore filler, small talk, and false starts."""


def _load_bedrock_bearer_token() -> str:
    """Pull the Bedrock API key from the Keychain unless the env var is already
    set (escape hatch for CI or manual override)."""
    existing = os.environ.get("AWS_BEARER_TOKEN_BEDROCK")
    if existing:
        return existing
    try:
        return get_password(service=DEFAULT_SERVICE)
    except KeychainError as e:
        raise RuntimeError(
            f"Could not read Bedrock API key from Keychain: {e}\n"
            f"Add one with:\n"
            f"    security add-generic-password -U -a meetingrec "
            f"-s {DEFAULT_SERVICE} -w <your-bedrock-api-key>\n"
            f"Or set AWS_BEARER_TOKEN_BEDROCK in the environment."
        ) from e


def summarize_to_markdown(transcript_markdown: str, model_id: str = DEFAULT_MODEL_ID) -> str:
    """Send the transcript to a Strands Agent backed by Bedrock Opus and return
    the markdown meeting notes it produces.

    The Bedrock bearer token is read from the macOS Keychain (service
    `meetingrec-bedrock`) and exposed as $AWS_BEARER_TOKEN_BEDROCK for the
    duration of the call. Region is taken from AWS_REGION / AWS_DEFAULT_REGION.
    """
    # Imported lazily so `--help` doesn't pay the strands import cost.
    from strands import Agent
    from strands.models import BedrockModel

    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    log.info("Calling Bedrock model %s (region=%s)", model_id, region or "<default>")

    token = _load_bedrock_bearer_token()
    # Scope the env mutation to this call only: save prior value, set ours,
    # restore on exit. boto3 reads AWS_BEARER_TOKEN_BEDROCK at client
    # construction time, so setting it here is sufficient.
    previous = os.environ.get("AWS_BEARER_TOKEN_BEDROCK")
    os.environ["AWS_BEARER_TOKEN_BEDROCK"] = token
    try:
        # Note: temperature is deprecated on Opus 4.7+ — the model rejects the
        # parameter entirely. Keep the call parameter-less for broadest compat.
        bedrock_kwargs: dict = {"model_id": model_id}
        if region:
            bedrock_kwargs["region_name"] = region
        model = BedrockModel(**bedrock_kwargs)
        agent = Agent(model=model, system_prompt=SYSTEM_PROMPT)

        user_prompt = (
            "Here is the diarized transcript. Produce the meeting notes in the format "
            "described.\n\n"
            f"{transcript_markdown}"
        )
        result = agent(user_prompt)
    finally:
        if previous is None:
            os.environ.pop("AWS_BEARER_TOKEN_BEDROCK", None)
        else:
            os.environ["AWS_BEARER_TOKEN_BEDROCK"] = previous

    message = getattr(result, "message", None)
    if isinstance(message, dict):
        parts = []
        for block in message.get("content", []) or []:
            if isinstance(block, dict) and "text" in block:
                parts.append(block["text"])
        if parts:
            return "\n".join(parts).strip()

    return str(result).strip()
