# meetingrec

A macOS CLI tool that records video-meeting audio and produces diarized
transcripts and Opus-summarized meeting notes — without depending on the
meeting host to enable transcription.

Two components:

- **`meetingrec`** — Swift CLI that captures your mic and system audio
  simultaneously to a single stereo WAV (mic on left, system audio on right)
  using ScreenCaptureKit and AVAudioEngine. No BlackHole, Loopback, or kernel
  extensions required.
- **`meetingrec-postprocess`** — Python companion that splits the channels,
  runs them through Amazon Transcribe (with multi-speaker diarization on the
  remote side), and sends the merged transcript to Claude Opus on Bedrock
  for meeting notes. `meetingrec` invokes this automatically after each
  recording.

No local ML models. No GPU required. Audio is uploaded to S3 in a region you
configure and processed by AWS.

## How it works

1. `meetingrec` captures two audio streams in parallel:
   - **System audio** via `SCStream` (`capturesAudio = true`,
     `excludesCurrentProcessAudio = true`) — the other side of your call.
   - **Microphone** via `AVAudioEngine.inputNode` — your voice.
2. Both streams are converted to 16kHz mono Float32 via `AVAudioConverter`,
   pushed into ring buffers, and then merged by a mixer thread that pops
   equal-sized chunks from each, interleaves them as stereo (mic=L, system=R),
   and appends int16 samples to the WAV file as they arrive (no full-recording
   memory buffering).
3. On `Ctrl-C`, both captures stop, the mixer drains, the WAV header is
   fixed up, and `meetingrec` shells out to `meetingrec-postprocess`.
4. The post-processor splits the stereo WAV into two mono files, uploads them
   to S3, runs two `StartTranscriptionJob` calls in parallel:
   - **mic** job: no diarization, all speech labeled `You`
   - **system** job: `ShowSpeakerLabels=True`, labels are mapped to
     `Speaker A`, `Speaker B`, …
5. The two transcripts are merged chronologically into a single diarized
   markdown document, which is then sent to Claude on Bedrock via the
   Strands Agents SDK to produce structured meeting notes.

Resilience features:

- **Audio device changes** (Bluetooth headsets connecting/disconnecting,
  AirPods pairing) are handled on the fly — `MicCapture` listens for
  `AVAudioEngineConfigurationChange` and rebuilds the tap with the new
  default-input format without interrupting the recording.
- **Zoom/Chime co-existence** — ScreenCaptureKit sometimes stops our stream
  when another SCKit client (Zoom, Chime, Teams) reconfigures; we auto-restart
  with backoff (up to 10 attempts).
- **Resumable post-processing** — if AWS credentials expire during the long
  Transcribe polling loop, a state file is left next to the WAV. Re-running
  the same command after re-authenticating skips upload/launch and reconnects
  to the jobs already running in AWS.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon recommended
- Swift 5.9+ for building `meetingrec`
- [`uv`](https://docs.astral.sh/uv/) for managing the Python post-processor
- `ffmpeg` on `$PATH` (`brew install ffmpeg`)
- An AWS account with:
  - An S3 bucket in your target region (default `us-west-2`)
  - Amazon Transcribe permissions
  - A Bedrock API key
- A macOS Keychain entry holding the Bedrock API key

## Build

### Swift CLI

```sh
swift build -c release
```

Binary: `.build/release/meetingrec`.

### Python post-processor

```sh
cd postprocess
uv sync
```

This creates `postprocess/.venv/` with ~50 packages (boto3, strands-agents,
no pytorch).

### Install both on `$PATH`

```sh
ln -sf "$(pwd)/.build/release/meetingrec"                               /usr/local/bin/meetingrec
ln -sf "$(pwd)/postprocess/.venv/bin/meetingrec-postprocess"            /usr/local/bin/meetingrec-postprocess
```

Symlinks (not copies) so `swift build` updates propagate automatically.

## One-time setup

### 1. macOS permissions

On first run, grant:

- **Privacy & Security → Screen & System Audio Recording**: add the
  `meetingrec` binary using the `+` button, toggle it on, relaunch. The
  automatic prompt sometimes doesn't appear; add the binary manually if so.
- **Privacy & Security → Microphone**: the embedded
  `NSMicrophoneUsageDescription` triggers the prompt automatically on first
  launch. If you run via `swift run`, grant mic access to your terminal
  instead (TCC attributes the request to the parent process).

### 2. AWS

```sh
aws s3 mb s3://my-meetingrec-staging --region us-west-2
```

Your IAM principal needs: `s3:{Put,Get,Delete}Object` on the bucket,
`transcribe:{Start,Get,Delete}TranscriptionJob`, and `sts:GetCallerIdentity`.

### 3. Bedrock API key in Keychain

Create a Bedrock API key in **AWS Console → Bedrock → API keys** (us-west-2),
then store it in the login keychain:

```sh
security add-generic-password -U \
    -a meetingrec \
    -s meetingrec-bedrock \
    -w 'YOUR-BEDROCK-API-KEY'
```

The post-processor reads this at summary time and sets
`AWS_BEARER_TOKEN_BEDROCK` for the Bedrock call only — S3 and Transcribe
continue to use your regular AWS session. This means Opus keeps working even
if your SSO session has expired by the time a long meeting finishes
uploading and transcribing.

First read per terminal/GUI session prompts macOS to allow access; click
**Always Allow**. Rotate with the same `add -U` command.

## Usage

```sh
meetingrec                              # writes ~/Recordings/meeting-<timestamp>.wav + transcript + notes
meetingrec ~/Desktop/client-call.wav    # explicit path
meetingrec -n                           # record only, skip transcription/summary
meetingrec -s                           # speaker-only: capture system audio only (mono WAV)
meetingrec --help
```

### Speaker-only mode

`-s` / `--speaker-only` records just the other side of the call. The mic is
not captured (and macOS won't prompt for microphone permission), and the
output is a mono 16kHz WAV instead of the default stereo. The post-processor
auto-detects the mono layout and runs a single diarized Transcribe job —
everyone in the recording is labeled `Speaker A`, `Speaker B`, … in order of
first appearance. There is no `You` channel in this mode.

Use this when you only need a record of what was said *to* you (e.g., a
talk you're attending, a webinar) and don't want your own audio in the
transcript.

Press `Ctrl-C` to stop recording. `meetingrec` finalizes the WAV, prints the
duration, and invokes `meetingrec-postprocess`. Total wall-clock for a
60-minute meeting: roughly 8–15 minutes of post-processing (Transcribe is the
dominant cost; it runs at ~5–10× realtime).

Outputs land next to the WAV:

- `meeting-<timestamp>.transcript.md` — diarized transcript
- `meeting-<timestamp>.notes.md` — Opus-summarized meeting notes

### Obsidian export

If `MEETINGREC_OBSIDIAN_VAULT` is set (or `--obsidian-vault` is passed to the
post-processor), the meeting notes are *additionally* copied into that vault
directory — the copy next to the WAV always remains. The vault copy differs
from the plain one in two ways:

- **Filename/title:** Opus generates a short descriptive title from the
  transcript (e.g. `Q3 Launch Timeline Review.md`) instead of the timestamp
  name. Name collisions get a numeric suffix rather than overwriting.
- **Frontmatter:** the note starts with Obsidian YAML frontmatter carrying
  the recording date and a `meeting-notes` tag:

  ```markdown
  ---
  title: Q3 Launch Timeline Review
  date: 2026-07-07 07:56
  tags:
    - meeting-notes
  ---
  ```

The export is best-effort: if the vault directory is missing or unwritable,
a warning is printed and the run still succeeds (the Recordings copy is the
source of truth).

### Resuming a post-process after expired credentials

If `meetingrec-postprocess` hit an auth failure mid-run, it leaves behind
`<wav>.meetingrec-state.json`. After re-authenticating (`aws sso login` or
equivalent), run:

```sh
meetingrec-postprocess /path/to/meeting-<timestamp>.wav
```

It detects the state file, skips the upload/launch, and reconnects to the
already-running Transcribe jobs. The state file is deleted on successful
completion.

### Automatic recording of Zoom meetings

`hooks/` contains a launchd agent that starts `meetingrec` when you join a
Zoom meeting and stops it (equivalent to Ctrl-C, so the WAV is finalized and
the post-processor runs) when the meeting ends:

```sh
./hooks/install-zoom-watcher.sh              # install + start
./hooks/install-zoom-watcher.sh --uninstall
```

How it works: `zoom-watcher.sh` polls every 5 seconds for Zoom's `CptHost`
helper process, which Zoom runs for exactly the duration of each meeting
(the main `zoom.us` process alone just means the app is open). When the
helper appears a recording starts; when it has been gone for 3 consecutive
polls (~15 s of grace, so a momentary blip doesn't split the recording) the
recording is stopped. Back-to-back meetings each get their own WAV.

Configuration lives in `~/.config/meetingrec/zoom-watcher.env` (created from
`hooks/zoom-watcher.env.example` on first install). launchd agents don't read
your shell profile, so `MEETINGREC_S3_BUCKET` / `AWS_REGION` must be set
there. You can also set `MEETINGREC_ZOOM_ARGS="-s"` for speaker-only
auto-recordings, or `-n` to skip post-processing. `MEETINGREC_OBSIDIAN_VAULT`
in the same file enables the Obsidian export (see above) for auto-recordings.

Caveats:

- `meetingrec` must already hold Screen Recording (and Microphone)
  permission — run it once manually first. If it can't start, the watcher
  retries twice, then logs and waits for the next meeting.
- If your AWS session has expired when a meeting ends, the recording is
  still saved; transcription fails and leaves a state file, and you resume
  it manually after `aws sso login` (see below).
- The config file is sourced once at watcher startup. After editing it,
  restart the watcher to pick up the change:
  `launchctl kickstart -k gui/$(id -u)/com.meetingrec.zoom-watcher`

#### Knowing it's working

There are three layers of evidence, in order of immediacy.

**1. The watcher log** — every decision the watcher makes, timestamped:

```sh
tail -f ~/Library/Logs/meetingrec/zoom-watcher.log
```

Within ~5 seconds of joining a meeting (one poll interval):

```
2026-07-07 10:02:15 meeting detected -> started meetingrec (pid 48123, log …/recording-2026-07-07-100215.log)
```

Within ~15 seconds of the call ending (the 3-poll grace period):

```
2026-07-07 10:47:31 meeting ended -> sending SIGINT to meetingrec (pid 48123)
```

Reading it: **no line after joining a call** means the watcher isn't
detecting the meeting (check `pgrep -x CptHost` mid-call — it should print a
pid). **`meetingrec exited 3 times this meeting; giving up…`** means
detection worked but `meetingrec` itself is failing to start — almost always
the Screen Recording permission (System Settings → Privacy & Security →
Screen & System Audio Recording; the binary must be granted directly, since
launchd, not your terminal, is the parent process).

**2. The per-recording log** — `meetingrec`'s own output, one file per
recording at the path printed in the watcher log line. It reads exactly like
a manual terminal run: `Recording started…` / `Output: …` at the start, and
after the meeting ends, `Stopping…`, `Saved: …`, `Duration: …`, followed by
the full post-processor output. Transcription/AWS errors (e.g. expired SSO
session) appear here, not in the watcher log.

**3. The artifacts** — the WAV appears in `~/Recordings/` immediately when
the recording starts and grows as audio arrives (~230 MB/hour), so a growing
file mid-call is direct proof capture is running:

```sh
ls -lh ~/Recordings/
```

The `.transcript.md` and `.notes.md` land next to it when post-processing
finishes (8–15 minutes for an hour of audio). You can also check the process
directly mid-call: `pgrep -fl meetingrec`.

#### Verifying after install (no real meeting needed)

1. Watcher is alive:

   ```sh
   launchctl print gui/$(id -u)/com.meetingrec.zoom-watcher | grep state   # state = running
   ```

   and the watcher log should end with
   `zoom-watcher started (poll 5s, end grace 15s)`.

2. Dry run: start a Zoom meeting alone (New Meeting — CptHost spawns even
   with no participants), watch the `meeting detected` line appear, talk for
   30 seconds, leave, and confirm the `meeting ended` line, then the saved
   WAV. To make the dry run cheap, temporarily set
   `MEETINGREC_ZOOM_ARGS="-n"` in the config (and restart the watcher, see
   above) so it skips the AWS transcription step.

### Standalone post-processing

Any WAV with mic-on-L, system-on-R layout works — not just meetingrec's
output. Useful for rerunning against the same recording while iterating on
the summarizer prompt:

```sh
meetingrec-postprocess /path/to/recording.wav
meetingrec-postprocess --skip-summary /path/to/recording.wav    # transcript only
meetingrec-postprocess --no-resume /path/to/recording.wav       # ignore stale state file
```

## Environment variables

| Variable | Required | Purpose |
|---|---|---|
| `MEETINGREC_S3_BUCKET` | yes | S3 bucket for audio staging |
| `AWS_REGION` | yes | Region for S3, Transcribe, and Bedrock (e.g. `us-west-2`) |
| `MEETINGREC_S3_PREFIX` | no | Object-key prefix (default `meetingrec/`) |
| `TRANSCRIBE_LANGUAGE` | no | Transcribe language code (default `en-US`) |
| `BEDROCK_MODEL_ID` | no | Override the Opus model ID (default `global.anthropic.claude-opus-4-7`) |
| `MEETINGREC_OBSIDIAN_VAULT` | no | Obsidian vault directory to copy meeting notes into (titled, tagged `meeting-notes`) |
| `MEETINGREC_POSTPROCESS` | no | Absolute path to `meetingrec-postprocess` binary; overrides `$PATH` lookup |

Plus whatever your AWS credential chain needs — `AWS_PROFILE`, SSO session,
assumed role, etc. The Bedrock key comes from Keychain, not env vars.

Recommended `~/.zshrc` entries:

```sh
export MEETINGREC_S3_BUCKET=<bucket-name>
export AWS_REGION=us-west-2
```

## Project layout

```
audio-capturer/
├── Package.swift                       # SPM manifest
├── Sources/meetingrec/                 # Swift CLI
│   ├── main.swift                      # lifecycle, SIGINT, post-processor invocation
│   ├── MicCapture.swift                # AVAudioEngine tap + route-change handling
│   ├── SystemAudioCapture.swift        # SCStream with auto-restart
│   ├── StereoMixer.swift               # merges ring buffers → int16 stereo
│   ├── MonoSink.swift                  # speaker-only path: ring buffer → int16 mono
│   ├── WAVWriter.swift                 # streaming WAV with header fixup on close
│   ├── FloatRingBuffer.swift
│   ├── AudioFormat.swift               # AVAudioConverter wrapper
│   ├── Permissions.swift               # TCC probes
│   └── Info.plist                      # embedded via linker for mic usage
├── hooks/                              # Zoom auto-record launchd agent
│   ├── zoom-watcher.sh                 # polls for Zoom's CptHost, start/stop meetingrec
│   ├── com.meetingrec.zoom-watcher.plist
│   ├── zoom-watcher.env.example        # config template (installed to ~/.config)
│   └── install-zoom-watcher.sh         # install/--uninstall
└── postprocess/                        # Python companion tool
    ├── pyproject.toml
    └── src/meetingrec_postprocess/
        ├── __main__.py                 # CLI entrypoint
        ├── transcribe.py               # ffmpeg split + Transcribe + merge
        ├── summarize.py                # Strands agent + Bedrock + Keychain auth
        ├── obsidian.py                 # titled + tagged copy into an Obsidian vault
        ├── keychain.py                 # security(1) wrapper
        ├── auth.py                     # STS preflight + AuthError classification
        └── state.py                    # resume state file
```

## Notes

- **Long meetings:** an hour of recording produces ~230 MB of WAV; memory
  stays flat during recording because samples are written as they arrive.
- **Clock drift:** the mic and system streams run on independent clocks and
  will drift slightly over long meetings. For transcription this is
  immaterial. If you need tight sync for another purpose, you'd need a
  drift-tracking resampler.
- **Cost:** Amazon Transcribe is ~$0.024/min of audio per job. We run two
  jobs per meeting (Transcribe rejects `ShowSpeakerLabels` +
  `ChannelIdentification` in the same request), so ~$2.88/hour of audio +
  a few cents of S3 + one Bedrock call.
- **See also:** `postprocess/README.md` for deeper detail on the transcription
  and summarization pipeline, IAM policy, and troubleshooting.
