#!/bin/bash

#sudo /usr/local/bin/oga_controls &
#ffplay -loglevel +quiet -seek_interval 1 -loop 0 -x 640 -y 480 "$1"
#sudo kill $(pidof oga_controls)
#printf "\033c" >> /dev/tty1

#. /etc/profile
#set_kill set "mpv"
sudo systemctl start mpv

xres="$(cat /sys/class/graphics/fb0/modes | grep -o -P '(?<=:).*(?=p-)' | cut -dx -f1)"
yres="$(cat /sys/class/graphics/fb0/modes | grep -o -P '(?<=:).*(?=p-)' | cut -dx -f2)"

sudo /usr/bin/mpv --fullscreen --geometry=${xres}x${yres} --hwdec=auto --vo=drm --input-ipc-server=/tmp/mpvsocket --config-dir=~/.config/mpv "${1}"

sudo systemctl stop mpv
exit 0
