#!/bin/bash
# Enroll the owner's voiceprint for ambient speaker diarization (self/other).
#
# Pulls single-speaker segments labeled as the owner from a remote VoiceLog
# database, copies the original audio read-only, trims + resamples each
# segment, and feeds them to `clawgate-diarizer enroll`. The originals and
# the live DB are never modified: the DB is snapshotted with sqlite .backup
# first, and all local material is deleted afterwards — only the voiceprint
# JSON remains.
#
# Required environment (no personal data is hardcoded — this repo is public):
#   ENROLL_REMOTE_HOST     ssh alias of the host with the VoiceLog data
#   ENROLL_SPEAKER_LABEL   segments.speaker_label value identifying the owner
# Optional:
#   ENROLL_VOICELOG_ROOT   VoiceLog root on the remote (default ~/projects/Mac/voicelog)
#   ENROLL_LIMIT           number of clips (default 15)
#
# Prereqs: scripts/provision-diarizer.sh has been run (helper + models ready),
# ffmpeg installed locally.
set -euo pipefail

HOST="${ENROLL_REMOTE_HOST:?set ENROLL_REMOTE_HOST (ssh alias)}"
LABEL="${ENROLL_SPEAKER_LABEL:?set ENROLL_SPEAKER_LABEL (owner's speaker_label)}"
VL_ROOT="${ENROLL_VOICELOG_ROOT:-~/projects/Mac/voicelog}"
LIMIT="${ENROLL_LIMIT:-15}"

DIARIZER="$HOME/Library/Application Support/ClawGate/diarizer/bin/clawgate-diarizer"
OUT="$HOME/Library/Application Support/ClawGate/diarizer/self.json"
WORK="$(mktemp -d /tmp/cg-enroll.XXXXXX)"
REMOTE_DB_COPY="/tmp/cg-enroll-vl.db"
trap 'rm -rf "$WORK"; ssh "$HOST" "rm -f $REMOTE_DB_COPY" || true' EXIT

[[ -x "$DIARIZER" ]] || { echo "diarizer helper missing — run scripts/provision-diarizer.sh first" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg required" >&2; exit 1; }

echo "[1/4] Snapshot remote VoiceLog DB (.backup — live DB untouched)"
ssh "$HOST" "sqlite3 $VL_ROOT/data/db/voicelog.db \".backup $REMOTE_DB_COPY\""

echo "[2/4] Select top $LIMIT single-speaker owner segments"
# NB: segments.confidence is a log-probability (negative; closer to 0 is
# better) — do not threshold it against 0..1 values.
cat > "$WORK/query.sql" <<EOF
.separator |
SELECT s.recording_id, r.original_path, s.start_sec, s.end_sec
FROM segments s JOIN recordings r ON r.id = s.recording_id
WHERE r.speaker_count = 1
  AND s.speaker_label = '$LABEL'
  AND (s.end_sec - s.start_sec) BETWEEN 10 AND 30
  AND s.low_confidence = 0
ORDER BY s.confidence DESC, r.vad_avg_prob DESC
LIMIT $LIMIT;
EOF
ssh "$HOST" "sqlite3 $REMOTE_DB_COPY" < "$WORK/query.sql" > "$WORK/segments.txt"
COUNT=$(grep -c . "$WORK/segments.txt" || true)
[[ "$COUNT" -gt 0 ]] || { echo "no matching segments for label" >&2; exit 1; }
echo "  $COUNT segments"

echo "[3/4] Copy originals (read-only) + trim/resample to 16k mono wav"
mkdir -p "$WORK/src" "$WORK/wavs"
i=0
while IFS='|' read -r rec path start end; do
  [[ -n "$path" ]] || continue
  i=$((i+1))
  scp -q "$HOST:$VL_ROOT/data/original/$path" "$WORK/src/$path"
  dur=$(echo "$end $start" | awk '{ print $1 - $2 }')
  ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$dur" \
    -i "$WORK/src/$path" -ar 16000 -ac 1 -c:a pcm_s16le \
    "$WORK/wavs/clip$(printf '%02d' "$i").wav"
done < "$WORK/segments.txt"

echo "[4/4] Enroll voiceprint"
"$DIARIZER" enroll --wav-dir "$WORK/wavs" --out "$OUT"
echo "voiceprint ready: $OUT (material deleted on exit)"
