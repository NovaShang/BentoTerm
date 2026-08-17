#!/bin/zsh
# v2 — SQUARE cut (2160x2160): top band carries chapter titles, bottom band
# the persistent subtitles (subs.ass burnt in the final pass). Voice chapter
# stays locked on the wheel's screen position: shell beat (T3 0.4-8.5, wheel
# over the left pane) then agent beat (T3 23.8-33.4, wheel over the center
# pane), split where the VO pivots on "More importantly".
# Mac-to-Mac boundaries are 0.4s crossfades: every segment on the A side of a
# fade is rendered 0.4s long, and the xfade chain consumes the handles.
set -e
cd "$(dirname "$0")"
C=assets/clips-v2; G=assets/gen; K=assets/cards; O=out/seg2; mkdir -p $O
ENC=(-r 60 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an)

MACFIT="scale=2060:-2,pad=2160:2160:(ow-iw)/2:(oh-ih)/2:black"          # wide window centered
GFIT="scale=2160:-2,pad=2160:2160:(ow-iw)/2:(oh-ih)/2:black"            # 16:9 generated shots
PORT="split[a][b];[a]scale=2160:2160:force_original_aspect_ratio=increase,crop=2160:2160,boxblur=40:2,eq=brightness=-0.15[bg];[b]scale=-2:1650[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2"

# --- plain segments -----------------------------------------------------------
# 01 cold open (5.9) — square crop of the center-top pane
ffmpeg -y -loglevel error -ss 0.5 -t 5.9 -i $C/T1.mov \
  -vf "crop=1300:1300:870:140,scale=2160:2160" $ENC $O/01.mp4
# 09-13 tail chapter (unchanged timing, square canvas)
ffmpeg -y -loglevel error -ss 3.2 -t 2.5 -i $G/G1.mp4 \
  -vf "tpad=stop_mode=clone:stop_duration=0.6,fade=t=out:st=2.2:d=0.8,$GFIT" $ENC $O/09.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G2.mp4 -vf "$GFIT" $ENC $O/10.mp4
ffmpeg -y -loglevel error -ss 2.5 -t 1.9 -i $C/T4.mov -filter_complex "$PORT" $ENC $O/11.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G3.mp4 -vf "$GFIT" $ENC $O/12.mp4
ffmpeg -y -loglevel error -ss 11.0 -t 2.0 -i $C/T5.mov -filter_complex "$PORT" $ENC $O/13.mp4
ffmpeg -y -loglevel error -loop 1 -t 7.3 -i $K/claim-sq.png -vf "fade=t=in:st=0.3:d=0.6" $ENC $O/14.mp4
ffmpeg -y -loglevel error -loop 1 -t 5.8 -i $K/end-sq.png -vf "fade=t=in:st=0.1:d=0.6" $ENC $O/15.mp4

# --- the crossfaded Mac chain (02..07) ---------------------------------------
# nominal durs: 02=2.0 03=5.3 04=4.9 05=3.6 06=8.1 07=9.6  (chain = 33.5)
# A-side segments get +0.4s of source as the fade handle.
# 02 reveal: closeup -> wide over the same T1 window
ffmpeg -y -loglevel error -ss 6.4 -t 2.4 -i $C/T1.mov -ss 6.4 -t 2.4 -i $C/T1.mov \
  -filter_complex "[0:v]crop=1300:1300:870:140,scale=2160:2160,setpts=PTS-STARTPTS[a];[1:v]$MACFIT,setpts=PTS-STARTPTS[b];[a][b]xfade=transition=fade:duration=1.6:offset=0.2" \
  $ENC $O/02.mp4
# 03 layout edit, tail-aligned (drop settles at the line's end)
ffmpeg -y -loglevel error -ss 27.7 -t 5.7 -i $C/T1.mov -vf "$MACFIT" $ENC $O/03.mp4
# 04 watch-static
ffmpeg -y -loglevel error -ss 22.6 -t 5.3 -i $C/T2.mov -vf "$MACFIT" $ENC $O/04.mp4
# 05 amber cycle at 2.5x
ffmpeg -y -loglevel error -ss 13.0 -t 10.0 -i $C/T2.mov \
  -vf "setpts=PTS/2.5,fps=60,$MACFIT" $ENC $O/05.mp4
# 06 voice->shell, wheel-locked crop (left pane)
ffmpeg -y -loglevel error -ss 0.4 -t 8.5 -i $C/T3.mov \
  -vf "crop=1300:1300:40:180,scale=2160:2160" $ENC $O/06.mp4
# 07 voice->agent, wheel-locked crop (center pane); ends past the send
ffmpeg -y -loglevel error -ss 23.8 -t 9.6 -i $C/T3.mov \
  -vf "crop=1300:1300:764:77,scale=2160:2160" $ENC $O/07.mp4

ffmpeg -y -loglevel error \
  -i $O/02.mp4 -i $O/03.mp4 -i $O/04.mp4 -i $O/05.mp4 -i $O/06.mp4 -i $O/07.mp4 \
  -filter_complex "[0][1]xfade=transition=fade:duration=0.4:offset=2.0[x1];[x1][2]xfade=transition=fade:duration=0.4:offset=7.3[x2];[x2][3]xfade=transition=fade:duration=0.4:offset=12.2[x3];[x3][4]xfade=transition=fade:duration=0.4:offset=15.8[x4];[x4][5]xfade=transition=fade:duration=0.4:offset=23.9" \
  $ENC $O/chain.mp4

# --- assemble, burn text, mux audio ------------------------------------------
for f in 01 chain 09 10 11 12 13 14 15; do echo "file 'seg2/$f.mp4'"; done > out/concat2.txt
ffmpeg -y -loglevel error -f concat -safe 0 -i out/concat2.txt -c copy out/video2.mp4
ffmpeg -y -loglevel error -i out/video2.mp4 -i audio/vo/full.mp3 \
  -filter_complex "[0:v]ass=filename=subs.ass[v];[1:a]adelay=1000|1000,apad[a]" \
  -map "[v]" -map "[a]" -r 60 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -t 62.5 out/v2.mp4
ffprobe -v error -show_entries format=duration -of csv=p=0 out/v2.mp4
echo DONE