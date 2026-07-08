"""Copy meeting notes into an Obsidian vault.

The vault copy gets YAML frontmatter (title, date, `meeting-notes` tag) and is
named after the model-generated meeting title. The plain copy next to the WAV
is untouched — this is an additional export, not a move.
"""
from __future__ import annotations

import datetime as _dt
import re
from pathlib import Path

TITLE_PREFIX = "TITLE:"

# Characters that are unsafe in filenames (macOS/Obsidian) — everything else,
# including spaces, is kept so vault filenames stay human-readable.
_FILENAME_UNSAFE = re.compile(r'[/\\:#^|\[\]"<>?*\x00-\x1f]')


def split_title(notes_md: str) -> tuple[str | None, str]:
    """Split the model's `TITLE: …` first line from the notes body.

    Returns (title, body). Title is None if the model didn't follow the
    format — callers fall back to the recording's filename stem.
    """
    lines = notes_md.lstrip().splitlines()
    if lines and lines[0].strip().startswith(TITLE_PREFIX):
        title = lines[0].strip()[len(TITLE_PREFIX):].strip().strip('"')
        body = "\n".join(lines[1:]).lstrip("\n")
        return (title or None), body
    return None, notes_md


def _safe_filename(title: str) -> str:
    name = _FILENAME_UNSAFE.sub("-", title).strip().strip(".")
    name = re.sub(r"\s+", " ", name)
    return name[:120] or "Meeting notes"


def export_note(
    notes_body: str,
    title: str,
    vault_dir: Path,
    recorded_at: _dt.datetime,
) -> Path:
    """Write the notes into the vault with frontmatter; return the new path.

    Filenames collide across recurring meetings with similar content, so an
    existing name gets a numeric suffix rather than being overwritten.
    """
    vault_dir = vault_dir.expanduser()
    if not vault_dir.is_dir():
        raise FileNotFoundError(f"Obsidian vault directory does not exist: {vault_dir}")

    frontmatter = "\n".join(
        [
            "---",
            f"title: {title}",
            f"date: {recorded_at.strftime('%Y-%m-%d %H:%M')}",
            "tags:",
            "  - meeting-notes",
            "---",
            "",
        ]
    )

    base = _safe_filename(title)
    dest = vault_dir / f"{base}.md"
    counter = 2
    while dest.exists():
        dest = vault_dir / f"{base} {counter}.md"
        counter += 1

    dest.write_text(frontmatter + notes_body.rstrip() + "\n", encoding="utf-8")
    return dest


def recording_datetime(wav: Path) -> _dt.datetime:
    """Best-effort timestamp for the recording: parse meetingrec's
    meeting-YYYY-MM-DD-HHMMSS naming, else fall back to file mtime."""
    m = re.search(r"(\d{4}-\d{2}-\d{2})-(\d{6})", wav.stem)
    if m:
        try:
            return _dt.datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H%M%S")
        except ValueError:
            pass
    return _dt.datetime.fromtimestamp(wav.stat().st_mtime)
