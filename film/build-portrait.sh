#!/bin/zsh
# TRUE 9:16 recompose (1080x1920). Wide Mac shots become full-height square
# crops INTO the source, panned per beat so the action stays in frame
# (amber beat pans left to the assistant column, the drag beat pans right to
# the drop zone); closeups reuse the square framings; the iPhone recording
# goes full-bleed; G shots take a center square; cards re-laid for portrait.
set -e
cd "$(dirname "$0")"
C=assets/clips-v2; G=assets/gen; K=assets/cards; O=out/segP; mkdir -p $O
ENC=(-r 60 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an)

PAD="pad=1080:1920:0:(oh-ih)/2:black"
COMPP="crop=2038:2038:502:0,scale=4320:4320:flags=lanczos"

# 01 cold open — pinned zoom + bottom shade, centered in the portrait canvas
ffmpeg -y -loglevel error -ss 0.5 -t 5.9 -i $C/T1.mov -i assets/text/shade.png \
  -filter_complex "[0:v]fps=60,$COMPP,zoompan=z='1.5677':x='2158-(iw/zoom)/2':y='1675-(ih/zoom)/2':d=1:s=1080x1080:fps=60[z];[1:v]scale=1080:1080[sh];[z][sh]overlay=0:0,$PAD" $ENC $O/01.mp4
# 02 reveal — zoom out to the center-pane square of the window
ffmpeg -y -loglevel error -ss 6.4 -t 2.4 -i $C/T1.mov -loop 1 -t 2.4 -i assets/text/shade.png \
  -filter_complex "[0:v]fps=60,$COMPP,zoompan=z='max(1.5677-0.5677*in/119,1)':x='2158-(iw/zoom)/2':y='1675-(ih/zoom)/2':d=1:s=1080x1080:fps=60[z];[1:v]scale=1080:1080,format=rgba,fade=t=out:st=0.1:d=0.7:alpha=1[sh];[z][sh]overlay=0:0,$PAD" $ENC $O/02.mp4
# 03 edit — pan right so the drag lands in frame
ffmpeg -y -loglevel error -ss 27.7 -t 5.7 -i $C/T1.mov -vf "crop=2038:2038:1094:0,scale=1080:1080,$PAD" $ENC $O/03.mp4
# 04/05 — pan left so the assistant (amber) column is fully visible
ffmpeg -y -loglevel error -ss 22.6 -t 5.3 -i $C/T2.mov -vf "crop=2038:2038:200:0,scale=1080:1080,$PAD" $ENC $O/04.mp4
ffmpeg -y -loglevel error -ss 13.0 -t 10.0 -i $C/T2.mov -vf "setpts=PTS/2.5,fps=60,crop=2038:2038:200:0,scale=1080:1080,$PAD" $ENC $O/05.mp4
# 06/07 voice — the square wheel framings
ffmpeg -y -loglevel error -ss 0.4 -t 11.0 -i $C/T3.mov -vf "crop=1300:1300:40:180,scale=1080:1080,$PAD" $ENC $O/06.mp4
ffmpeg -y -loglevel error -ss 25.0 -t 12.6 -i $C/T3.mov -vf "crop=1300:1300:764:77,scale=1080:1080,$PAD" $ENC $O/07.mp4

ffmpeg -y -loglevel error \
  -i $O/02.mp4 -i $O/03.mp4 -i $O/04.mp4 -i $O/05.mp4 -i $O/06.mp4 -i $O/07.mp4 \
  -filter_complex "[0][1]xfade=transition=fade:duration=0.4:offset=2.0[x1];[x1][2]xfade=transition=fade:duration=0.4:offset=7.3[x2];[x2][3]xfade=transition=fade:duration=0.4:offset=12.2[x3];[x3][4]xfade=transition=fade:duration=0.4:offset=15.8[x4];[x4][5]xfade=transition=fade:duration=0.4:offset=26.4" \
  $ENC $O/chain.mp4

# tail: G shots center-square; iPad blurred-fill; iPhone full-bleed
ffmpeg -y -loglevel error -ss 3.2 -t 2.5 -i $G/G1.mp4 \
  -vf "tpad=stop_mode=clone:stop_duration=0.6,fade=t=out:st=2.2:d=0.8,crop=1440:1440:560:0,scale=1080:1080,$PAD" $ENC $O/09.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G2.mp4 -vf "crop=1440:1440:560:0,scale=1080:1080,$PAD" $ENC $O/10.mp4
ffmpeg -y -loglevel error -ss 2.5 -t 3.4 -i $C/T4.mov \
  -filter_complex "[0:v]split[a][b];[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=40:2,eq=brightness=-0.15[bg];[b]scale=-2:1500[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2" $ENC $O/11.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G3.mp4 -vf "crop=1440:1440:560:0,scale=1080:1080,$PAD" $ENC $O/12.mp4
ffmpeg -y -loglevel error -ss 10.5 -t 3.5 -i $C/T5.mov \
  -vf "scale=1080:-2,crop=1080:1920:0:(ih-1920)/2" $ENC $O/13.mp4

for lang in "" "-zh"; do
  ffmpeg -y -loglevel error -loop 1 -t 7.3 -i $K/claim$lang-p.png -vf "fade=t=in:st=0.3:d=0.6" $ENC $O/14$lang.mp4
  ffmpeg -y -loglevel error -loop 1 -t 5.8 -i $K/end$lang-p.png -vf "fade=t=in:st=0.1:d=0.6" $ENC $O/15$lang.mp4
done
for lang in "" "-zh"; do
  for f in 01 chain 09 10 11 12 13 14$lang 15$lang; do echo "file 'segP/$f.mp4'"; done > out/concatP$lang.txt
  ffmpeg -y -loglevel error -f concat -safe 0 -i out/concatP$lang.txt -c copy out/videoP$lang.mp4
done
ffprobe -v error -show_entries format=duration -of csv=p=0 out/videoP.mp4
echo P-SEGMENTS-DONE