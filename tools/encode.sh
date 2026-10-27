#!/bin/bash
# Cut an audio source into the chunks speakerbox plays.
#
#   encode.sh <chunk-dir> desktop [pulse-source]   this machine's audio out
#   encode.sh <chunk-dir> file <path> [...]        a file, or a playlist of them
#   encode.sh <chunk-dir> loop <path>              one file, over and over
#   encode.sh <chunk-dir> url <url>                an Icecast/HTTP/SRT stream
#   encode.sh <chunk-dir> mic [pulse-source]       a microphone or line in
#
# The chunk directory is <world>/speakerbox/<stream>, e.g.
#   server/data/worlds/testworld/speakerbox/live
#
# Defaults are mono 22050 Hz Vorbis at 48 kbit/s, which is the shape world-mode
# speakers need (OpenAL will not pan a stereo buffer) and the cheapest on the
# listener's memory: every second of audio delivered costs each client about
# 2 bytes per sample for the rest of the session. Override with the environment:
#
#   CHUNK=6 RATE=22050 CHANNELS=1 BITRATE=48k KEEP_MINUTES=5
set -euo pipefail

DIR=${1:-}
MODE=${2:-}
shift 2 2>/dev/null || true

CHUNK=${CHUNK:-6}
RATE=${RATE:-22050}
CHANNELS=${CHANNELS:-1}
BITRATE=${BITRATE:-48k}
KEEP_MINUTES=${KEEP_MINUTES:-5}

if [ -z "$DIR" ] || [ -z "$MODE" ]; then
    sed -n '2,20p' "$0" | sed 's/^# \?//'
    exit 2
fi

command -v ffmpeg >/dev/null || { echo "ffmpeg is not installed" >&2; exit 1; }
mkdir -p "$DIR"

# Pruning is the producer's job: speakerbox copies each chunk's bytes when it
# pushes them, so deleting a file it has already sent is safe, and the manifest
# is intersected with the directory listing so vanished names are ignored.
prune() {
    while true; do
        find "$DIR" -maxdepth 1 -name '*.ogg' -mmin "+$KEEP_MINUTES" -delete 2>/dev/null || true
        sleep 60
    done
}
prune & PRUNER=$!
trap 'kill $PRUNER 2>/dev/null || true' EXIT

# -segment_list is the "this chunk is finished" signal the mod reads: ffmpeg
# appends to it as each segment is closed, which is what ready_mode = manifest
# expects. Drop to ready_mode = lag if you replace this with your own producer
# and cannot write a manifest.
OUT=(
    -ac "$CHANNELS" -ar "$RATE" -c:a libvorbis -b:a "$BITRATE"
    -f segment
    -segment_time "$CHUNK"
    -segment_format ogg
    -segment_list "$DIR/chunks.list"
    -segment_list_type flat
    -segment_list_flags +live
    -segment_list_size 20
    -reset_timestamps 1
    "$DIR/%08d.ogg"
)

echo "chunks -> $DIR  (${CHUNK}s, ${CHANNELS}ch, ${RATE}Hz, $BITRATE)"

case "$MODE" in
desktop)
    # @DEFAULT_MONITOR@ is whatever is coming out of the default sink, which is
    # what you want for DJ software, a browser tab, anything. `pactl list short
    # sources` names the others.
    SRC=${1:-@DEFAULT_MONITOR@}
    echo "capturing $SRC"
    exec ffmpeg -hide_banner -loglevel warning -f pulse -i "$SRC" "${OUT[@]}"
    ;;
mic)
    SRC=${1:-default}
    echo "capturing $SRC"
    exec ffmpeg -hide_banner -loglevel warning -f pulse -i "$SRC" "${OUT[@]}"
    ;;
file)
    # -re matters: without it ffmpeg encodes the whole file as fast as it can,
    # the mod finds a hundred finished chunks at once, and a live stream throws
    # all but the newest away.
    if [ "$#" -eq 1 ]; then
        exec ffmpeg -hide_banner -loglevel warning -re -i "$1" "${OUT[@]}"
    fi
    LIST=$(mktemp)
    trap 'kill $PRUNER 2>/dev/null || true; rm -f "$LIST"' EXIT
    for f in "$@"; do
        printf "file '%s'\n" "$(realpath "$f")" >> "$LIST"
    done
    exec ffmpeg -hide_banner -loglevel warning -re -f concat -safe 0 -i "$LIST" "${OUT[@]}"
    ;;
loop)
    exec ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i "$1" "${OUT[@]}"
    ;;
url)
    exec ffmpeg -hide_banner -loglevel warning -i "$1" "${OUT[@]}"
    ;;
*)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac
