"""ASR + diarization for meetingrec WAVs using Amazon Transcribe.

Input: a stereo WAV with mic on left (you) and system audio on right (remote
participants, possibly multiple speakers).

Strategy:
  1. Split the stereo WAV into two mono WAVs with ffmpeg.
  2. Upload both mono WAVs to a user-provided S3 bucket.
  3. Start two Transcribe jobs in parallel:
       - mic:    ShowSpeakerLabels=False (single speaker, relabeled "You")
       - system: ShowSpeakerLabels=True, MaxSpeakerLabels=N for diarization
  4. Poll both jobs until they finish; download JSON output.
  5. Merge both transcripts chronologically.
  6. Clean up S3 objects and the state file.

The work is split into `launch_jobs` and `finish_jobs` so that if the process
dies between them (e.g. expired creds while polling), a subsequent rerun can
skip the upload and reconnect to the jobs that are already running.
"""
from __future__ import annotations

import json
import logging
import subprocess
import tempfile
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

from .auth import AuthError, classify_boto_error
from .state import RunState, STATE_VERSION, delete as delete_state, save as save_state, state_path_for

log = logging.getLogger(__name__)


@dataclass
class Segment:
    start: float          # seconds
    end: float            # seconds
    speaker: str          # "You", "Speaker A", etc.
    text: str


# ---------- ffmpeg / S3 / Transcribe primitives ----------

def _run_ffmpeg_split(wav_path: Path, left_out: Path, right_out: Path) -> None:
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", str(wav_path),
        "-filter_complex", "[0:a]channelsplit=channel_layout=stereo[L][R]",
        "-map", "[L]", "-ac", "1", "-ar", "16000", str(left_out),
        "-map", "[R]", "-ac", "1", "-ar", "16000", str(right_out),
    ]
    log.info("Splitting stereo → mono: %s", " ".join(cmd))
    subprocess.run(cmd, check=True)


def _upload_to_s3(s3_client, bucket: str, key: str, path: Path) -> str:
    log.info("Uploading %s → s3://%s/%s", path, bucket, key)
    s3_client.upload_file(str(path), bucket, key)
    return f"s3://{bucket}/{key}"


def _delete_from_s3(s3_client, bucket: str, key: str) -> None:
    try:
        s3_client.delete_object(Bucket=bucket, Key=key)
    except Exception as e:  # noqa: BLE001
        log.warning("Failed to delete s3://%s/%s: %s", bucket, key, e)


def _start_transcription_job(
    transcribe_client,
    job_name: str,
    media_uri: str,
    language_code: str,
    show_speaker_labels: bool,
    max_speaker_labels: Optional[int],
) -> None:
    settings: dict[str, Any] = {}
    if show_speaker_labels:
        settings["ShowSpeakerLabels"] = True
        settings["MaxSpeakerLabels"] = max_speaker_labels or 10

    kwargs: dict[str, Any] = {
        "TranscriptionJobName": job_name,
        "LanguageCode": language_code,
        "MediaFormat": "wav",
        "Media": {"MediaFileUri": media_uri},
    }
    if settings:
        kwargs["Settings"] = settings
    log.info("Starting Transcribe job %s (speaker_labels=%s)", job_name, show_speaker_labels)
    transcribe_client.start_transcription_job(**kwargs)


def _wait_for_job(transcribe_client, job_name: str, poll_seconds: float = 5.0) -> dict:
    """Blocks until the job reaches COMPLETED or FAILED.

    Converts auth-related botocore errors to AuthError so the caller can
    preserve the state file and print a friendly re-login message.
    """
    while True:
        try:
            resp = transcribe_client.get_transcription_job(TranscriptionJobName=job_name)
        except BaseException as exc:  # noqa: BLE001
            reason = classify_boto_error(exc)
            if reason is not None:
                raise AuthError(reason) from exc
            raise
        job = resp["TranscriptionJob"]
        status = job["TranscriptionJobStatus"]
        if status == "COMPLETED":
            return job
        if status == "FAILED":
            reason = job.get("FailureReason", "unknown")
            raise RuntimeError(f"Transcribe job {job_name} failed: {reason}")
        log.info("Job %s status=%s; sleeping %.1fs", job_name, status, poll_seconds)
        time.sleep(poll_seconds)


def _download_transcript(job: dict) -> dict:
    """Fetch the JSON transcript from the presigned TranscriptFileUri."""
    uri = job["Transcript"]["TranscriptFileUri"]
    log.info("Downloading transcript from %s", uri[:80] + "…")
    with urllib.request.urlopen(uri) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ---------- Transcribe JSON → Segments ----------

def _items_to_segments(
    transcript_json: dict,
    default_speaker: str,
) -> list[Segment]:
    results = transcript_json.get("results", {})
    items = results.get("items", [])

    segments: list[Segment] = []
    cur_speaker: Optional[str] = None
    cur_start: Optional[float] = None
    cur_end: Optional[float] = None
    cur_tokens: list[str] = []

    def flush():
        nonlocal cur_speaker, cur_start, cur_end, cur_tokens
        if cur_tokens and cur_speaker is not None and cur_start is not None:
            text = "".join(cur_tokens).strip()
            if text:
                segments.append(Segment(
                    start=cur_start,
                    end=cur_end if cur_end is not None else cur_start,
                    speaker=cur_speaker,
                    text=text,
                ))
        cur_speaker = None
        cur_start = None
        cur_end = None
        cur_tokens = []

    for item in items:
        item_type = item.get("type")
        alternatives = item.get("alternatives", [])
        content = alternatives[0].get("content", "") if alternatives else ""
        if not content:
            continue

        if item_type == "punctuation":
            if cur_tokens:
                cur_tokens[-1] = cur_tokens[-1] + content
            continue

        start = float(item["start_time"])
        end = float(item["end_time"])
        speaker = item.get("speaker_label") or default_speaker

        if cur_speaker is None:
            cur_speaker = speaker
            cur_start = start
        elif speaker != cur_speaker:
            flush()
            cur_speaker = speaker
            cur_start = start

        if cur_tokens:
            cur_tokens.append(" " + content)
        else:
            cur_tokens.append(content)
        cur_end = end

    flush()
    return segments


# ---------- Public pipeline: launch → finish ----------

def launch_jobs(
    wav_path: Path,
    s3_bucket: str,
    region: str = "us-west-2",
    language_code: str = "en-US",
    max_remote_speakers: Optional[int] = None,
    s3_prefix: str = "meetingrec/",
    keep_s3_objects: bool = False,
) -> RunState:
    """Split channels, upload to S3, start both Transcribe jobs, persist state.

    Returns a RunState that finish_jobs() can consume. Also writes the same
    state to `<wav>.meetingrec-state.json` so a rerun after a crash can pick up.
    """
    import boto3
    session = boto3.session.Session(region_name=region)
    s3 = session.client("s3")
    transcribe = session.client("transcribe")

    run_id = uuid.uuid4().hex[:12]
    mic_key = f"{s3_prefix}{run_id}/mic.wav"
    sys_key = f"{s3_prefix}{run_id}/system.wav"
    mic_job = f"meetingrec-{run_id}-mic"
    sys_job = f"meetingrec-{run_id}-sys"

    try:
        with tempfile.TemporaryDirectory(prefix="meetingrec-pp-") as tmp_str:
            tmp = Path(tmp_str)
            mic_wav = tmp / "mic.wav"
            sys_wav = tmp / "system.wav"
            _run_ffmpeg_split(wav_path, mic_wav, sys_wav)

            mic_uri = _upload_to_s3(s3, s3_bucket, mic_key, mic_wav)
            sys_uri = _upload_to_s3(s3, s3_bucket, sys_key, sys_wav)

        _start_transcription_job(
            transcribe, mic_job, mic_uri, language_code,
            show_speaker_labels=False, max_speaker_labels=None,
        )
        _start_transcription_job(
            transcribe, sys_job, sys_uri, language_code,
            show_speaker_labels=True, max_speaker_labels=max_remote_speakers,
        )
    except BaseException as exc:  # noqa: BLE001
        reason = classify_boto_error(exc)
        if reason is not None:
            raise AuthError(reason) from exc
        raise

    state = RunState(
        version=STATE_VERSION,
        wav_path=str(wav_path.resolve()),
        s3_bucket=s3_bucket,
        s3_prefix=s3_prefix,
        region=region,
        language_code=language_code,
        max_remote_speakers=max_remote_speakers,
        keep_s3_objects=keep_s3_objects,
        run_id=run_id,
        mic_s3_key=mic_key,
        system_s3_key=sys_key,
        mic_job_name=mic_job,
        system_job_name=sys_job,
    )
    save_state(state, state_path_for(wav_path))
    log.info("Launched jobs %s and %s; state persisted.", mic_job, sys_job)
    return state


def finish_jobs(state: RunState) -> list[Segment]:
    """Poll the jobs identified by `state` to completion, download transcripts,
    merge into time-ordered segments, and clean up (S3 objects + jobs + state file).

    Raises AuthError on credential issues; in that case the state file is
    preserved so the user can rerun after re-auth.
    """
    import boto3
    session = boto3.session.Session(region_name=state.region)
    s3 = session.client("s3")
    transcribe = session.client("transcribe")

    try:
        # Poll both concurrently so total wait = max(mic, sys), not sum.
        with ThreadPoolExecutor(max_workers=2) as pool:
            mic_future = pool.submit(_wait_for_job, transcribe, state.mic_job_name)
            sys_future = pool.submit(_wait_for_job, transcribe, state.system_job_name)
            mic_job = mic_future.result()
            sys_job = sys_future.result()

        mic_json = _download_transcript(mic_job)
        sys_json = _download_transcript(sys_job)
    except AuthError:
        # Don't clean up — preserve state so the user can rerun after re-auth.
        raise

    mic_segments = _items_to_segments(mic_json, default_speaker="You")
    # Mic side is single-speaker; override any label Transcribe might emit.
    mic_segments = [Segment(s.start, s.end, "You", s.text) for s in mic_segments]

    sys_segments_raw = _items_to_segments(sys_json, default_speaker="Speaker")

    # Map Transcribe's "spk_0" / "spk_1" labels to "Speaker A" / "B" / … in
    # the order they first appear, so attribution is stable and readable.
    label_map: dict[str, str] = {}
    next_ord = 0
    for seg in sys_segments_raw:
        if seg.speaker not in label_map:
            label_map[seg.speaker] = f"Speaker {chr(ord('A') + next_ord)}"
            next_ord += 1
    sys_segments = [
        Segment(s.start, s.end, label_map.get(s.speaker, s.speaker), s.text)
        for s in sys_segments_raw
    ]

    all_segments = mic_segments + sys_segments
    all_segments.sort(key=lambda s: s.start)

    # Successful completion: clean up.
    for job_name in (state.mic_job_name, state.system_job_name):
        try:
            transcribe.delete_transcription_job(TranscriptionJobName=job_name)
        except Exception as e:  # noqa: BLE001
            log.debug("delete_transcription_job(%s) failed: %s", job_name, e)
    if not state.keep_s3_objects:
        _delete_from_s3(s3, state.s3_bucket, state.mic_s3_key)
        _delete_from_s3(s3, state.s3_bucket, state.system_s3_key)

    delete_state(state_path_for(Path(state.wav_path)))
    return all_segments


def transcribe_and_diarize(
    wav_path: Path,
    s3_bucket: str,
    region: str = "us-west-2",
    language_code: str = "en-US",
    max_remote_speakers: Optional[int] = None,
    s3_prefix: str = "meetingrec/",
    keep_s3_objects: bool = False,
) -> list[Segment]:
    """Convenience wrapper that does a fresh launch_jobs + finish_jobs.
    For the resumable path, callers should use launch_jobs / finish_jobs directly."""
    state = launch_jobs(
        wav_path,
        s3_bucket=s3_bucket,
        region=region,
        language_code=language_code,
        max_remote_speakers=max_remote_speakers,
        s3_prefix=s3_prefix,
        keep_s3_objects=keep_s3_objects,
    )
    return finish_jobs(state)


# ---------- Markdown rendering ----------

def segments_to_markdown(segments: list[Segment]) -> str:
    lines = ["# Transcript", ""]
    for seg in segments:
        ts = _fmt_timestamp(seg.start)
        lines.append(f"**[{ts}] {seg.speaker}:** {seg.text}")
        lines.append("")
    return "\n".join(lines)


def _fmt_timestamp(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h:d}:{m:02d}:{s:02d}"
    return f"{m:d}:{s:02d}"
