"""Minimal macOS Keychain accessor via /usr/bin/security.

We use Keychain to store a Bedrock API key (a long-lived bearer token) so the
summarization step doesn't depend on short-lived AWS SSO session credentials.
S3 and Transcribe still use the regular AWS credential chain; only the
Bedrock client picks up the bearer token (boto3 reads it from the
AWS_BEARER_TOKEN_BEDROCK environment variable).

Design choice: shell out to `security` rather than pulling in a Python
Keychain dependency. It's always present on macOS, requires no install, and
the access prompt (first read per terminal session) comes from the OS itself.
"""
from __future__ import annotations

import subprocess

DEFAULT_SERVICE = "meetingrec-bedrock"


class KeychainError(RuntimeError):
    """Raised when the Keychain lookup fails for any reason."""


def get_password(service: str = DEFAULT_SERVICE, account: str | None = None) -> str:
    """Fetch a generic-password from the login keychain.

    On first use in a new terminal/GUI session macOS will prompt the user to
    allow access; subsequent reads are silent. If the user denies the prompt
    we surface a KeychainError so the caller can fall back gracefully.
    """
    cmd = ["security", "find-generic-password", "-s", service, "-w"]
    if account:
        cmd.extend(["-a", account])
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        raise KeychainError(
            f"Keychain lookup for service={service!r} failed: {stderr or 'not found or access denied'}"
        ) from exc
    token = result.stdout.rstrip("\n")
    if not token:
        raise KeychainError(f"Keychain entry for service={service!r} is empty.")
    return token
