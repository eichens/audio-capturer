"""State file for resuming a transcription run after an interruption.

When Transcribe jobs are launched we persist their identifiers (plus the
S3 keys that back them) to a small JSON file alongside the WAV. If the
process dies or creds expire mid-polling, a subsequent rerun can pick
up exactly where we left off — no re-uploading, no duplicate jobs,
no double billing.

The state file is deleted once the run completes successfully.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional

STATE_VERSION = 2


@dataclass
class RunState:
    version: int
    wav_path: str
    s3_bucket: str
    s3_prefix: str
    region: str
    language_code: str
    max_remote_speakers: Optional[int]
    keep_s3_objects: bool
    run_id: str
    # mic_* are None in speaker-only (mono) runs — only the system track exists.
    mic_s3_key: Optional[str]
    system_s3_key: str
    mic_job_name: Optional[str]
    system_job_name: str


def state_path_for(wav_path: Path) -> Path:
    """State file lives next to the WAV: `<wav>.meetingrec-state.json`."""
    return wav_path.with_suffix(wav_path.suffix + ".meetingrec-state.json")


def save(state: RunState, path: Path) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(asdict(state), indent=2), encoding="utf-8")
    tmp.replace(path)  # atomic on POSIX


def load(path: Path) -> Optional[RunState]:
    if not path.is_file():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("version") != STATE_VERSION:
        # Unknown/older format — refuse to resume from it.
        return None
    return RunState(**data)


def delete(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
