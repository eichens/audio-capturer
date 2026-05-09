"""AWS authentication helpers.

Goals:
  - Preflight check at process start so we fail fast on expired creds before
    doing any work (ffmpeg split, uploads, etc.).
  - Recognize auth-related boto3 errors during long-running work (polling
    Transcribe jobs) and surface them as AuthError so the CLI can print a
    clean "re-login and retry" message instead of a stack trace.

Design notes:
  - boto3 refreshes short-lived creds automatically when it can (IMDS,
    container credentials, refreshable SSO sessions). The case that bites is
    an expired *SSO session* mid-run — then refresh fails and we get a
    botocore exception.
  - We catch the usual suspects by error code AND by exception class where
    they exist, since botocore sometimes surfaces these via generic
    ClientError vs. a typed exception depending on the service.
"""
from __future__ import annotations

import logging
from typing import Optional

log = logging.getLogger(__name__)


# Error codes that mean "your credentials are no longer valid — go re-auth."
# Assembled from botocore + sts/sso behavior across services.
AUTH_ERROR_CODES = frozenset({
    "ExpiredToken",
    "ExpiredTokenException",
    "InvalidClientTokenId",
    "UnrecognizedClientException",
    "TokenRefreshRequired",
    "RequestExpired",
    "SSOTokenLoadError",
    "UnauthorizedSSOTokenError",
    "AccessDeniedException",      # sometimes returned when the session is invalid
})


class AuthError(RuntimeError):
    """Raised when AWS auth is expired / missing / unusable.

    The CLI catches this and prints instructions instead of a stack trace.
    """


def classify_boto_error(exc: BaseException) -> Optional[str]:
    """If `exc` looks like an auth failure, return a short human-readable
    reason. Otherwise return None (meaning: some other error, rethrow)."""
    # Imported lazily so help output doesn't drag in botocore.
    from botocore.exceptions import (
        ClientError,
        NoCredentialsError,
        PartialCredentialsError,
        SSOTokenLoadError,
        TokenRetrievalError,
        UnauthorizedSSOTokenError,
    )

    if isinstance(exc, (
        NoCredentialsError,
        PartialCredentialsError,
        SSOTokenLoadError,
        TokenRetrievalError,
        UnauthorizedSSOTokenError,
    )):
        return str(exc) or type(exc).__name__

    if isinstance(exc, ClientError):
        code = exc.response.get("Error", {}).get("Code", "")
        if code in AUTH_ERROR_CODES:
            message = exc.response.get("Error", {}).get("Message", "") or code
            return f"{code}: {message}"

    return None


def reauth_instructions() -> str:
    """Prose to show the user when we detect an auth failure."""
    return (
        "Your AWS credentials have expired or aren't usable.\n"
        "  - If you use SSO:        run `aws sso login` (or `aws sso login --profile <name>`).\n"
        "  - If you use a role:     re-assume the role.\n"
        "  - If you use a profile:  refresh the credentials in ~/.aws/credentials.\n"
        "Then rerun this same command — it will automatically resume from where it left off."
    )


def preflight(region: str) -> None:
    """Call sts:GetCallerIdentity to confirm creds are usable. Raises AuthError
    on any auth-related failure; other errors propagate normally."""
    import boto3
    try:
        session = boto3.session.Session(region_name=region)
        session.client("sts").get_caller_identity()
    except BaseException as exc:  # noqa: BLE001
        reason = classify_boto_error(exc)
        if reason is not None:
            raise AuthError(reason) from exc
        raise
