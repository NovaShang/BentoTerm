#!/bin/zsh
# v1 rough cut — assembles film/out/v1.mp4 against audio/vo/full.mp3.
# Film time = audio time + 1.0s lead. Cut points from docs/promo-video.md §1
# and the frame-level scouting of clips-v2 (T2 amber cycle #2 = 13–22s, sped
# 2.5x into its 3.6s beat; L7 re-shows L6's moment closer — intentional).
set -e
cd "$(dirname "$0")"
C=assets/clips-v2; G=assets/gen; K=assets/cards; O=out/seg; mkdir -p $O
ENC=(-r 60 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an)

# Mac full-frame: fit height into 2560x1440, pillarbox black
MACFIT="scale=-2:1440,pad=2560:1440:(ow-iw)/2:0:black"
# portrait comp: blurred cover behind, clip fit-height in front
PORT="split[a][b];[a]scale=2560:1440:force_original_aspect_ratio=increase,crop=2560:1440,boxblur=40:2,eq=brightness=-0.15[bg];[b]scale=-2:1440[fg];[bg][fg]overlay=(W-w)/2:0"

# 01 cold open (5.9s) — center-top pane upper 16:9 region
ffmpeg -y -loglevel error -ss 0.5 -t 5.9 -i $C/T1.mov \
  -vf "crop=1276:718:884:188,scale=2560:1440" $ENC $O/01.mp4
# 02 reveal (2.0s) — crossfade cropped -> full over the same source window
ffmpeg -y -loglevel error -ss 6.4 -t 2.0 -i $C/T1.mov -ss 6.4 -t 2.0 -i $C/T1.mov \
  -filter_complex "[0:v]crop=1276:718:884:188,scale=2560:1440,setpts=PTS-STARTPTS[a];[1:v]$MACFIT,setpts=PTS-STARTPTS[b];[a][b]xfade=transition=fade:duration=1.6:offset=0.2" \
  $ENC $O/02.mp4
# 03 bento box / layout edit (5.3s) — TAIL-aligned: the drop settles as the
# line ends (divider tug 27.7-28, drag with drop-zone glow 29.5-32, settle 32.5)
ffmpeg -y -loglevel error -ss 27.7 -t 5.3 -i $C/T1.mov -vf "$MACFIT" $ENC $O/03.mp4
# 04 watch-static (4.9s) — T2 tail, everything back to work
ffmpeg -y -loglevel error -ss 22.6 -t 4.9 -i $C/T2.mov -vf "$MACFIT" $ENC $O/04.mp4
# 05 amber cycle (3.6s) — T2 13-22s at 2.5x
ffmpeg -y -loglevel error -ss 13.0 -t 9.0 -i $C/T2.mov \
  -vf "setpts=PTS/2.5,fps=60,$MACFIT" $ENC $O/05.mp4
# 06 voice wheel (5.8s)
ffmpeg -y -loglevel error -ss 20.5 -t 5.8 -i $C/T3.mov -vf "$MACFIT" $ENC $O/06.mp4
# 07 speak to agent (5.4s)
ffmpeg -y -loglevel error -ss 26.3 -t 5.4 -i $C/T3.mov -vf "$MACFIT" $ENC $O/07.mp4
# 08 transcript closeup (6.5s) — same beat, 1.55x closer
ffmpeg -y -loglevel error -ss 27.5 -t 6.5 -i $C/T3.mov \
  -vf "crop=2020:1136:404:159,scale=2560:1440" $ENC $O/08.mp4
# 09 lid close (3.1s) — G1 closing half, fade to black
ffmpeg -y -loglevel error -ss 3.2 -t 2.5 -i $G/G1.mp4 \
  -vf "tpad=stop_mode=clone:stop_duration=0.6,fade=t=out:st=2.2:d=0.8,scale=2560:1440" $ENC $O/09.mp4
# 10 sofa (1.5s) + 11 iPad (1.9s)
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G2.mp4 -vf "scale=2560:1440" $ENC $O/10.mp4
ffmpeg -y -loglevel error -ss 2.5 -t 1.9 -i $C/T4.mov -filter_complex "$PORT" $ENC $O/11.mp4
# 12 train (1.5s) + 13 iPhone (2.0s)
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G3.mp4 -vf "scale=2560:1440" $ENC $O/12.mp4
ffmpeg -y -loglevel error -ss 11.0 -t 2.0 -i $C/T5.mov -filter_complex "$PORT" $ENC $O/13.mp4
# 14 claim card (7.3s), 15 endcard (5.8s)
ffmpeg -y -loglevel error -loop 1 -t 7.3 -i $K/claim.png -vf "fade=t=in:st=0.3:d=0.6" $ENC $O/14.mp4
ffmpeg -y -loglevel error -loop 1 -t 5.8 -i $K/end.png -vf "fade=t=in:st=0.1:d=0.6" $ENC $O/15.mp4

for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do echo "file 'seg/$i.mp4'"; done > out/concat.txt
ffmpeg -y -loglevel error -f concat -safe 0 -i out/concat.txt -c copy out/video.mp4
# audio: VO enters at 1.0s film time
ffmpeg -y -loglevel error -i out/video.mp4 -itsoffset 1.0 -i audio/vo/full.mp3 \
  -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest out/v1.mp4 2>/dev/null || \
ffmpeg -y -loglevel error -i out/video.mp4 -i audio/vo/full.mp3 \
  -filter_complex "[1:a]adelay=1000|1000,apad[a]" -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -shortest out/v1.mp4
ffprobe -v error -show_entries format=duration -of csv=p=0 out/v1.mp4
echo DONE