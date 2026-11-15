#!/bin/bash
# adsp-sleep-test.sh - does the ADSP sleep with the sensors up? (RetroForge issue #46)
#
#   adsp-sleep-test.sh            measure now (stops audio for ~30 s, then starts it again)
#   adsp-sleep-test.sh --apply    add the test setting for the next boots, then reboot and measure again
#   adsp-sleep-test.sh --remove   remove the test setting, then reboot
#
# Run as root on RetroForge. The test setting gives the ADSP's Bluetooth sensing hub a UART that does
# not exist, in the per-boot copy of the sensor registry only. Nothing is written to persist.
set -u
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
UNIT=hexagonrpcd-adsp-sensorspd.service
DROPIN=/etc/systemd/system/$UNIT.d/90-issue46-test.conf
REG=/run/msm-firmware-loader/hexagonrpc/sensors/persist/registry/registry
STATS=/sys/kernel/debug/qcom_stats

case "${1:-}" in
--apply)
	mkdir -p "$(dirname $DROPIN)"
	cat > $DROPIN <<'D'
[Service]
ExecStartPre=+/bin/sh -c 'r=/run/msm-firmware-loader/hexagonrpc/sensors/persist/registry/registry; [ -d $$r ] && [ ! -e $$r/qsh_ble_config ] && printf %%s \'{"qsh_ble_config":{"owner":"qsh_ble","uart_instance":{"type":"int","ver":"0","data":"99"}}}\' > $$r/qsh_ble_config && chown fastrpc:fastrpc $$r/qsh_ble_config; true'
D
	systemctl daemon-reload
	echo "test setting added. Reboot, then run this script again without arguments."; exit 0 ;;
--remove)
	rm -f $DROPIN; rmdir "$(dirname $DROPIN)" 2>/dev/null; systemctl daemon-reload
	echo "test setting removed. Reboot to go back to the stock behaviour."; exit 0 ;;
esac

num() { sed -n "s/^$2: *//p" $STATS/$1 2>/dev/null; }
[ -r $STATS/adsp ] || { mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null; }
[ -r $STATS/adsp ] || { echo "no $STATS/adsp: cannot measure on this kernel"; exit 1; }

echo "model:      $(tr -d '\0' < /sys/firmware/devicetree/base/model)"
echo "build:      $(sed -n 's/^VERSION=//p' /etc/os-release) kernel $(uname -r)"
echo "uptime:     $(cut -d' ' -f1 /proc/uptime) s"
echo "sensors:    $UNIT is $(systemctl is-active $UNIT)"
if [ -e $REG/qsh_ble_config ]; then echo "hub entry:  present ($(cat $REG/qsh_ble_config))"
elif [ -d $REG ]; then echo "hub entry:  absent"
else echo "hub entry:  no registry copy at $REG"; fi
[ -e $DROPIN ] && echo "test setting: installed" || echo "test setting: not installed"

U=$(id -u player 2>/dev/null)
audio() { [ -n "$U" ] && su - player -c "XDG_RUNTIME_DIR=/run/user/$U systemctl --user $1 pipewire.socket pipewire-pulse.socket pipewire wireplumber pipewire-pulse" >/dev/null 2>&1; }
echo "stopping audio for the measurement..."
audio stop; sleep 8
open=$(grep -l RUNNING /proc/asound/card*/pcm*/sub*/status 2>/dev/null | wc -l)
[ "$open" = 0 ] || echo "warning: $open audio stream(s) still running; the ADSP stays awake while one is open"
a=$(num adsp "Accumulated Duration"); c=$(num adsp Count); i=$(num adsp_island Count); t0=$(date +%s%N)
sleep 20
b=$(num adsp "Accumulated Duration"); d=$(num adsp Count); j=$(num adsp_island Count); t1=$(date +%s%N)
audio start
awk -v a="$a" -v b="$b" -v c="$c" -v d="$d" -v i="${i:-0}" -v j="${j:-0}" -v t0="$t0" -v t1="$t1" 'BEGIN {
	dt = (t1 - t0) / 1e9; pct = 100 * (b - a) / 19200000 / dt
	printf "RESULT:     ADSP asleep %.0f %% of %.1f s (sleep entries +%d, island entries +%d)\n", pct, dt, d - c, j - i
	if (pct < 20) print "            -> the ADSP is held awake"
	else if (pct > 80) print "            -> the ADSP sleeps"
	else print "            -> in between: run it again with the device left idle" }'
