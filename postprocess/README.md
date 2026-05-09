# meetingrec-postprocess

Python companion tool that turns a `meetingrec` stereo WAV into:

1. A **diarized transcript** (markdown) via **Amazon Transcribe**, splitting
   "You" (mic channel) from "Speaker A / B / C …" (system channel, diarized
   by Transcribe's built-in speaker identification).
2. **Meeting notes** (markdown), produced by Claude Opus on AWS Bedrock via the
   Strands Agents SDK.

No local ML models. No pytorch. Audio is uploaded to S3 and processed by AWS.

## How it plugs into meetingrec

`meetingrec` automatically invokes `meetingrec-postprocess` after it finalizes
the WAV on `Ctrl-C`. Opt out with `MEETINGREC_NO_POSTPROCESS=1`.

You can also run it standalone on any existing WAV:

```sh
meetingrec-postprocess --s3-bucket my-transcribe-bucket ~/Recordings/meeting.wav
```

Outputs are written next to the WAV:

- `meeting.transcript.md` — diarized transcript
- `meeting.notes.md` — Opus-generated meeting notes

## Install

Managed with [`uv`](https://docs.astral.sh/uv/). Light dependency set (boto3
+ strands-agents), no large model downloads.

```sh
cd postprocess
uv sync
```

Then either add the venv to your PATH or set `$MEETINGREC_POSTPROCESS`:

```sh
export PATH="$(pwd)/.venv/bin:$PATH"
# or:
export MEETINGREC_POSTPROCESS="$(pwd)/.venv/bin/meetingrec-postprocess"
```

## Prerequisites

### AWS account setup

All work happens in one region (default: **us-west-2**).

1. **S3 bucket** for staging audio. Create one in us-west-2:
   ```sh
   aws s3 mb s3://my-meetingrec-staging --region us-west-2
   ```
   Nothing fancy required — the tool uploads, Transcribe reads, tool deletes.
2. **IAM permissions** on the principal running the tool (used for S3 and
   Transcribe; the Bedrock call is authenticated separately, see below):
   - `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` on the bucket
   - `transcribe:StartTranscriptionJob`, `transcribe:GetTranscriptionJob`,
     `transcribe:DeleteTranscriptionJob`
   - `sts:GetCallerIdentity` (used as a preflight check)
3. **Bedrock API key** (bearer token), stored in the macOS Keychain. See
   *Bedrock auth* below. The summarize step does NOT use your SSO/IAM
   session — this is deliberate so Opus still works after your session expires.
4. **Bedrock model access** enabled for Claude Opus 4.7 (or whichever model)
   in us-west-2. Request access in the Bedrock console under *Model access*.

### Bedrock auth (one-time setup)

The summary step reads a long-lived Bedrock API key from the macOS Keychain.
Mint a key in the AWS console (Bedrock → *API keys*), then store it:

```sh
security add-generic-password -U \
    -a meetingrec \
    -s meetingrec-bedrock \
    -w 'YOUR-BEDROCK-API-KEY'
```

Flags:
- `-U` — update the entry if it already exists (idempotent).
- `-a meetingrec` — the account name (arbitrary; must match on reads).
- `-s meetingrec-bedrock` — the service name the tool looks up.
- `-w '…'` — the password value. Quote it so shell metacharacters don't bite.

Verify:

```sh
security find-generic-password -s meetingrec-bedrock -w
```

First read in a new terminal/GUI session prompts you to allow access; after
that it's silent.

To rotate, run the same `add-generic-password -U` command with the new key.
To remove:

```sh
security delete-generic-password -s meetingrec-bedrock
```

### ffmpeg

Used to split the stereo WAV into mono L/R channels.

```sh
brew install ffmpeg
```

### Configure the tool

```sh
export MEETINGREC_S3_BUCKET=my-meetingrec-staging
export AWS_REGION=us-west-2
# plus standard AWS credential config: AWS_PROFILE, AWS_ACCESS_KEY_ID, SSO session, etc.
```

## CLI reference

```
meetingrec-postprocess [-h] --s3-bucket BUCKET [--s3-prefix PREFIX]
                       [--keep-s3-objects] [--region REGION]
                       [--language LANG] [--max-remote-speakers N]
                       [--bedrock-model-id ID] [--skip-summary]
                       [--no-resume] [-v]
                       wav
```

Useful flags:

- `--max-remote-speakers N`: upper bound on distinct remote speakers Transcribe
  should find (default 10). Lowering it improves accuracy when you know the
  true count.
- `--keep-s3-objects`: leave the uploaded WAVs in S3 after the run (for
  debugging). Default is to delete them.
- `--skip-summary`: produce only the diarized transcript.
- `--no-resume`: ignore any existing state file and start fresh.
- `-v`: verbose logging (shows each upload, job start, poll, and download).

## Handling expired credentials

Transcription uses your short-lived AWS session (SSO or assumed role); long
meetings or slow polls can outlast the session. Two safety nets:

1. **Preflight:** on startup the tool calls `sts:GetCallerIdentity`. If your
   creds are expired, it prints a clear re-auth message and exits cleanly
   before doing any work.
2. **Resume state:** once jobs are launched, the tool writes
   `<wav>.meetingrec-state.json` next to the WAV. If anything fails after
   that (including an auth error mid-poll), rerun the same command after
   re-authing — the tool skips upload and reconnects to the already-running
   Transcribe jobs. The state file is deleted on successful completion.

The summarize step reads the Bedrock API key from Keychain, so it is
*not* affected by AWS session expiry — it keeps working after a long meeting
even if your SSO token has lapsed.

## Environment variables

| Variable | Purpose |
|---|---|
| `MEETINGREC_S3_BUCKET` | S3 bucket for audio staging (required) |
| `MEETINGREC_S3_PREFIX` | Key prefix under the bucket (default `meetingrec/`) |
| `AWS_REGION` | Region for S3, Transcribe, and Bedrock (default `us-west-2`) |
| `TRANSCRIBE_LANGUAGE` | Transcribe language code (default `en-US`) |
| `BEDROCK_MODEL_ID` | Override the Opus model ID |
| `MEETINGREC_POSTPROCESS` | Absolute path to the `meetingrec-postprocess` binary meetingrec should call |

> Tip: to skip the post-processor for a single run, use `meetingrec -n` (no env var needed).

## How it works

1. `ffmpeg` splits the stereo WAV into `mic.wav` (left) and `system.wav` (right),
   each 16kHz mono.
2. Both files are uploaded to `s3://<bucket>/<prefix><run-id>/{mic,system}.wav`.
3. Two `StartTranscriptionJob` calls run in parallel:
   - **mic job**: no speaker diarization. All speech is labeled "You".
   - **system job**: `ShowSpeakerLabels=True, MaxSpeakerLabels=N`.
     Transcribe's `spk_0`, `spk_1`, … are renamed to "Speaker A", "Speaker B", …
     in the order they first appear.
4. Transcripts are downloaded (via the presigned URL Transcribe returns),
   parsed into time-ordered segments, merged chronologically, and written as
   markdown.
5. Uploaded audio objects and the two Transcribe jobs are deleted (best-effort
   cleanup).
6. The full transcript is sent to Claude Opus on Bedrock via Strands; the
   returned markdown is saved as `<wav>.notes.md`.

## Why two jobs?

Amazon Transcribe rejects requests that set both `ShowSpeakerLabels=True` and
`ChannelIdentification=True`. We want both attributions (mic = You, remote =
diarized), so two single-channel jobs is the cleanest path.

Cost is ~2× a single job: at Transcribe's $0.024/min, a 60-minute meeting
costs ~$2.88 to transcribe, plus pennies of S3 and a Bedrock call.

## Timing

Expect end-to-end wall-clock of roughly **1/5 to 1/10 of realtime** for the
Transcribe step — i.e. a 60-minute meeting finishes in roughly 6–12 minutes.
Upload is typically the second-longest phase after Transcribe itself
(~230 MB for a 60-min WAV).
