#!/bin/sh
# Regenerates the HLS fixtures in this directory with ffmpeg, ffprobe and python3. The
# committed files are the output of this script; rerun it only if the fixtures need to
# change, since encoder output (and with it a few byte counts) varies between ffmpeg versions.
#
#   muxed/   H.264 (with B-frames) + AAC in one MPEG-TS, 3 x 2 s segments. Timestamps start
#            3.7 s before the 33-bit PTS wraps, so the wrap falls inside the second segment.
#   split/   The YouTube shape: video-only MPEG-TS plus a separate packed-audio rendition
#            (ADTS AAC behind an ID3 PRIV transportStreamTimestamp tag).
#   alt/     One 2 s muxed segment at a different resolution, for discontinuity tests.
set -eu
cd "$(dirname "$0")"

FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}
FFPROBE=${FFPROBE:-/opt/homebrew/bin/ffprobe}
VIDEO="-c:v libx264 -preset veryslow -profile:v high -pix_fmt yuv420p -bf 2 -g 15 -keyint_min 15 -sc_threshold 0 -b:v 30k -maxrate 50k -bufsize 50k"
AUDIO="-c:a aac -b:a 32k -ar 44100 -ac 2"
SOURCE="-f lavfi -i testsrc2=size=160x90:rate=15 -f lavfi -i sine=frequency=440:beep_factor=4:sample_rate=44100"
QUIET="-hide_banner -loglevel error -y"

rm -rf muxed split alt
mkdir muxed split alt

# shellcheck disable=SC2086
$FFMPEG $QUIET $SOURCE -t 6 $VIDEO $AUDIO \
    -output_ts_offset 95440 \
    -f hls -hls_time 2 -hls_list_size 0 -hls_segment_filename 'muxed/seg%d.ts' muxed/media.m3u8

# The hls muxer writes the audio rendition as audio-only MPEG-TS. Keep its playlist and
# master, then repack each segment below.
# shellcheck disable=SC2086
$FFMPEG $QUIET $SOURCE -t 6 $VIDEO $AUDIO \
    -output_ts_offset 40000 \
    -map 0:v -map 1:a -f hls -hls_time 2 -hls_list_size 0 \
    -var_stream_map 'v:0,agroup:aud,name:video a:0,agroup:aud,name:audio' \
    -master_pl_name master.m3u8 \
    -hls_segment_filename 'split/%v%d.ts' 'split/%v.m3u8'

# Repack: raw ADTS behind an ID3v2.4 tag whose PRIV frame carries the segment's first PTS
# as a 33-bit 90 kHz value in 8 big-endian bytes, as Apple's packed-audio format specifies.
for ts in split/audio*.ts; do
    aac="${ts%.ts}.aac"
    pts=$($FFPROBE -v error -select_streams a -show_entries packet=pts -of default=nw=1:nk=1 "$ts" | head -1)
    $FFMPEG $QUIET -i "$ts" -c copy -f adts "$aac.tmp"
    python3 - "$pts" "$aac.tmp" "$aac" <<'EOF'
import struct, sys
pts, source, target = int(sys.argv[1]) & ((1 << 33) - 1), sys.argv[2], sys.argv[3]
def synchsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
payload = b"com.apple.streaming.transportStreamTimestamp\x00" + struct.pack(">Q", pts)
frame = b"PRIV" + synchsafe(len(payload)) + b"\x00\x00" + payload
tag = b"ID3\x04\x00\x00" + synchsafe(len(frame)) + frame
open(target, "wb").write(tag + open(source, "rb").read())
EOF
    rm "$ts" "$aac.tmp"
done
sed -i '' 's/\.ts$/.aac/' split/audio.m3u8

# shellcheck disable=SC2086
$FFMPEG $QUIET -f lavfi -i testsrc2=size=96x54:rate=15 -f lavfi -i sine=frequency=880:sample_rate=44100 -t 2 \
    $VIDEO $AUDIO -output_ts_offset 500 \
    -f hls -hls_time 2 -hls_list_size 0 -hls_segment_filename 'alt/seg%d.ts' alt/media.m3u8

du -ck muxed split alt | tail -1
