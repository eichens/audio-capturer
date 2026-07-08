"""CLI entrypoint: meetingrec-postprocess <wav-path>

Runs diarized transcription via Amazon Transcribe and (optionally) produces
meeting notes via Bedrock Opus. Writes next to the input:

    <wav>.transcript.md   — diarized transcript
    <wav>.notes.md        — Opus meeting notes

If a run is interrupted after jobs are launched (e.g. expired credentials
while polling), a state file `<wav>.meetingrec-state.json` is left behind.
Rerunning the same command picks up from the polling stage — no duplicate
uploads, no duplicate Transcribe jobs.
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

from .auth import AuthError, preflight, reauth_instructions
from .obsidian import export_note, recording_datetime, split_title
from .state import load as load_state, state_path_for
from .summarize import DEFAULT_MODEL_ID, summarize_to_markdown
from .transcribe import finish_jobs, launch_jobs, segments_to_markdown


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="meetingrec-postprocess",
        description="Transcribe a meetingrec WAV via Amazon Transcribe and summarize via Bedrock Opus.",
    )
    p.add_argument("wav", type=Path, help="Path to the stereo WAV produced by meetingrec.")
    p.add_argument(
        "--s3-bucket",
        default=os.environ.get("MEETINGREC_S3_BUCKET"),
        help="S3 bucket for audio staging. Required. Set $MEETINGREC_S3_BUCKET to avoid passing every run.",
    )
    p.add_argument(
        "--s3-prefix",
        default=os.environ.get("MEETINGREC_S3_PREFIX", "meetingrec/"),
        help="Object-key prefix under the bucket (default: 'meetingrec/').",
    )
    p.add_argument(
        "--keep-s3-objects",
        action="store_true",
        help="Don't delete the uploaded mono WAVs from S3 after the run.",
    )
    p.add_argument(
        "--region",
        default=os.environ.get("AWS_REGION", "us-west-2"),
        help="AWS region for S3, Transcribe, Bedrock (default: us-west-2).",
    )
    p.add_argument(
        "--language",
        default=os.environ.get("TRANSCRIBE_LANGUAGE", "en-US"),
        help="Transcribe language code (default: en-US).",
    )
    p.add_argument(
        "--max-remote-speakers",
        type=int,
        default=None,
        help="Upper bound on remote speakers (Transcribe's MaxSpeakerLabels; default 10).",
    )
    p.add_argument(
        "--bedrock-model-id",
        default=os.environ.get("BEDROCK_MODEL_ID", DEFAULT_MODEL_ID),
        help=f"Bedrock model ID for summarization (default: {DEFAULT_MODEL_ID}).",
    )
    p.add_argument(
        "--obsidian-vault",
        type=Path,
        default=os.environ.get("MEETINGREC_OBSIDIAN_VAULT") or None,
        help="Obsidian vault directory to copy the meeting notes into (with a "
        "meeting-notes frontmatter tag and a model-generated title). "
        "Set $MEETINGREC_OBSIDIAN_VAULT to avoid passing every run.",
    )
    p.add_argument(
        "--skip-summary",
        action="store_true",
        help="Only produce the diarized transcript; skip the Opus summary step.",
    )
    p.add_argument(
        "--no-resume",
        action="store_true",
        help="Ignore any existing state file and start a fresh run.",
    )
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def _print_auth_failure(err: AuthError) -> None:
    print(
        f"meetingrec-postprocess: AWS auth failed ({err}).\n\n"
        f"{reauth_instructions()}",
        file=sys.stderr,
    )


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    wav: Path = args.wav
    if not wav.is_file():
        print(f"meetingrec-postprocess: not a file: {wav}", file=sys.stderr)
        return 1

    transcript_path = wav.with_suffix(".transcript.md")
    notes_path = wav.with_suffix(".notes.md")
    state_path = state_path_for(wav)

    # MARK: detect resume vs. fresh run
    state = None if args.no_resume else load_state(state_path)

    # MARK: preflight AWS creds before doing any real work
    try:
        preflight(args.region if state is None else state.region)
    except AuthError as e:
        _print_auth_failure(e)
        if state is not None:
            print(
                f"\nExisting state file found at {state_path}; rerun this exact command "
                f"after re-auth to resume.",
                file=sys.stderr,
            )
        return 3

    # MARK: phase A — launch jobs (or skip if resuming)
    if state is None:
        if not args.s3_bucket:
            print(
                "meetingrec-postprocess: --s3-bucket (or $MEETINGREC_S3_BUCKET) is required.\n"
                "Amazon Transcribe reads the audio from S3; create or choose a bucket in "
                f"{args.region} and pass it here.",
                file=sys.stderr,
            )
            return 1

        print(f"Transcribing {wav.name} via Amazon Transcribe ({args.region})...")
        try:
            state = launch_jobs(
                wav,
                s3_bucket=args.s3_bucket,
                region=args.region,
                language_code=args.language,
                max_remote_speakers=args.max_remote_speakers,
                s3_prefix=args.s3_prefix,
                keep_s3_objects=args.keep_s3_objects,
            )
        except AuthError as e:
            _print_auth_failure(e)
            return 3
    else:
        mode = "stereo (mic+system)" if state.mic_job_name else "speaker-only (mono)"
        print(
            f"Resuming from existing state ({state_path.name}, {mode}):\n"
            f"  run_id={state.run_id}\n"
            f"  mic_job={state.mic_job_name or '(none)'}\n"
            f"  sys_job={state.system_job_name}"
        )

    # MARK: phase B — poll + download + merge
    try:
        segments = finish_jobs(state)
    except AuthError as e:
        _print_auth_failure(e)
        print(
            f"\nState file preserved at {state_path}. Rerun this exact command "
            f"after re-auth to resume — no duplicate work will be done.",
            file=sys.stderr,
        )
        return 3

    transcript_md = segments_to_markdown(segments)
    transcript_path.write_text(transcript_md, encoding="utf-8")
    print(f"Wrote transcript: {transcript_path}")

    if args.skip_summary:
        return 0

    print(f"Summarizing with {args.bedrock_model_id} ...")
    try:
        notes_md = summarize_to_markdown(transcript_md, model_id=args.bedrock_model_id)
    except Exception as e:  # noqa: BLE001
        from .auth import classify_boto_error
        reason = classify_boto_error(e)
        if reason is not None:
            _print_auth_failure(AuthError(reason))
            print(
                f"Transcript already saved to {transcript_path}. Rerun this exact "
                f"command after re-auth and the transcript will be reused (Bedrock "
                f"is the only remaining step).",
                file=sys.stderr,
            )
            return 3
        print(
            f"meetingrec-postprocess: summarization failed: {e}\n"
            f"Transcript saved to {transcript_path}; rerun with --skip-summary or "
            f"fix the issue and retry.",
            file=sys.stderr,
        )
        return 2

    title, notes_body = split_title(notes_md)
    notes_path.write_text(notes_body, encoding="utf-8")
    print(f"Wrote meeting notes: {notes_path}")

    # MARK: Obsidian export (best-effort — the Recordings copy above is the
    # source of truth, so a vault problem must not fail the run)
    if args.obsidian_vault:
        try:
            vault_note = export_note(
                notes_body,
                title=title or wav.stem,
                vault_dir=args.obsidian_vault,
                recorded_at=recording_datetime(wav),
            )
            print(f"Copied notes to Obsidian: {vault_note}")
        except OSError as e:
            print(
                f"meetingrec-postprocess: Obsidian export failed: {e}\n"
                f"Notes are still available at {notes_path}.",
                file=sys.stderr,
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
