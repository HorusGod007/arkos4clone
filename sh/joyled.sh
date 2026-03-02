#!/usr/bin/env bash
# ============================================================
# Joystick LED Controller (multi-device, dialog-based)
# Author: lcdyk
# Backends: mcu_led, gpio, ws2812
# ============================================================

set -euo pipefail
export TERM=linux

# ==================== 配置 ====================
CONSOLE_DETECT="${CONSOLE_DETECT:-/usr/local/bin/console_detect}"
MCU_LED_BIN="${MCU_LED_BIN:-/usr/bin/mcu_led}"
WS2812CTL_BIN="${WS2812CTL_BIN:-/usr/bin/ws2812}"
GPTOKEYB_BIN="${GPTOKEYB_BIN:-/opt/inttools/gptokeyb}"
SDL_DB_PATH="${SDL_DB_PATH:-/opt/inttools/gamecontrollerdb.txt}"
KEYS_GPTK_PATH="${KEYS_GPTK_PATH:-/opt/inttools/keys.gptk}"
CONSOLE_FONT="${CONSOLE_FONT:-/usr/share/consolefonts/Lat7-Terminus16.psf.gz}"
JOYLED_HOME_FILE="${JOYLED_HOME_FILE:-/home/ark/.joyled}"
STATE_DIR="${STATE_DIR:-/var/lib/joyled}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state}"
CURR_TTY="${CURR_TTY:-/dev/tty1}"

# mcu_led GPIO/UART
UART_DEV="${UART_DEV:-/dev/ttyS2}"
GPIO_NUM="${GPIO_NUM:-65}"
GPIO_DIR="/sys/class/gpio/gpio${GPIO_NUM}"

# gpio LED 节点
LED_BLUE="/sys/class/leds/blue:joy/brightness"
LED_GREEN="/sys/class/leds/green:joy/brightness"
LED_RED="/sys/class/leds/red:joy/brightness"

# ==================== 全局变量 ====================
DEVICE_NAME=""
LED_TYPE=""
LAST_CHOICE=""

# ==================== 权限 ====================
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

# ==================== 设备检测 ====================
detect_device() {
  if [[ -x "$CONSOLE_DETECT" ]]; then
    eval "$("$CONSOLE_DETECT" -s)"
  else
    DEVICE_NAME="$(cat /boot/.console 2>/dev/null || echo unknown)"
    # 后备检测
    case "$DEVICE_NAME" in
      xf35h|xf40h|k36s|r36tmax) LED_TYPE="mcu_led" ;;
      mymini|r36ultra|xgb36|mini40) LED_TYPE="gpio" ;;
      dc40v|dc35v|xf28|r36max2) LED_TYPE="ws2812" ;;
      *) LED_TYPE="unsupported" ;;
    esac
    return
  fi
  
  # 根据 LED_TYPE 确定后端
  case "$LED_TYPE" in
    mcu_led|gpio|ws2812) ;;
    *) LED_TYPE="unsupported" ;;
  esac
}

# ==================== 工具函数 ====================
have_cmd() { command -v "$1" >/dev/null 2>&1; }
tee_root() { sudo tee "$1" >/dev/null; }

fatal_msg() {
  local msg="$1"
  if have_cmd dialog; then
    dialog --msgbox "$msg" 7 68 > "$CURR_TTY"
  else
    echo "$msg"; read -r -p "Press Enter..." _
  fi
  printf "\e[?25h" > "$CURR_TTY"
  exit 0
}

# ==================== 状态持久化 ====================
save_state() {
  local color="$1"
  [[ "$color" == "off" || "$color" == "OFF" ]] && { rm -f "$JOYLED_HOME_FILE" 2>/dev/null || true; return 0; }
  
  local dir; dir="$(dirname "$JOYLED_HOME_FILE")"
  mkdir -p "$dir" "$STATE_DIR" 2>/dev/null || true
  
  local tmp; tmp="$(mktemp)"
  echo "MODEL=${DEVICE_NAME}" > "$tmp"
  echo "COLOR=${color}" >> "$tmp"
  
  install -m 0644 -o ark -g ark "$tmp" "$JOYLED_HOME_FILE" 2>/dev/null || {
    cp -f "$tmp" "$JOYLED_HOME_FILE"
    chown ark:ark "$JOYLED_HOME_FILE" 2>/dev/null || true
  }
  rm -f "$tmp"
  echo "$color" | sudo tee "$STATE_FILE" >/dev/null || true
}

load_saved_color() {
  [[ -r "$JOYLED_HOME_FILE" ]] || return 1
  grep -E '^COLOR=' "$JOYLED_HOME_FILE" 2>/dev/null | tail -n1 | cut -d= -f2
}

load_last_choice() {
  [[ -s "$STATE_FILE" ]] && LAST_CHOICE="$(sudo cat "$STATE_FILE" 2>/dev/null)" || true
}

# ==================== 菜单配置 ====================
declare -A MENU_ITEMS=(
  # mcu_led 菜单
  ["mcu_led"]="off:Turn off LED
red:Solid Red
green:Solid Green
blue:Solid Blue
orange:Solid Orange
purple:Solid Purple
cyan:Solid Cyan
white:Solid White
breath_red:Breathing Red
breath_green:Breathing Green
breath_blue:Breathing Blue
breath_orange:Breathing Orange
breath_purple:Breathing Purple
breath_cyan:Breathing Cyan
breath_white:Breathing White
breath:Breathing (generic)
flow:Flow effect"

  # gpio 菜单
  ["gpio"]="off:Turn off LED
red:Solid Red
green:Solid Green
blue:Solid Blue
white:Solid White
orange:Solid Orange
yellow:Solid Yellow
purple:Solid Purple"

  # ws2812 菜单
  ["ws2812"]="off:Turn off LED
scrolling:Scrolling effect
breathing:General breathing
breathing_red:Breathing Red
breathing_green:Breathing Green
breathing_blue:Breathing Blue
breathing_blue_red:Breathing Magenta
breathing_green_blue:Breathing Cyan
breathing_red_green:Breathing Yellow
breathing_red_green_blue:Breathing RGB
red_green_blue:Solid White
blue_red:Solid Magenta
blue:Solid Blue
green_blue:Solid Cyan
green:Solid Green
red_green:Solid Yellow
red:Solid Red"
)

get_menu_items() {
  local backend="$1"
  echo "${MENU_ITEMS[$backend]}"
}

choice_valid() {
  local target="$1" backend="$2"
  echo "${MENU_ITEMS[$backend]}" | grep -q "^${target}:"
}

# ==================== Backend: mcu_led ====================
declare -A MCU_MODES=(
  [red]=3 [green]=1 [blue]=2 [white]=7 [orange]=5 [purple]=6 [cyan]=4
  [breath_red]=19 [breath_green]=17 [breath_blue]=18 [breath_white]=23
  [breath_orange]=21 [breath_purple]=22 [breath_cyan]=20 [breath]=24 [flow]=8
)

ensure_gpio() {
  [[ -d "$GPIO_DIR" ]] || echo "$GPIO_NUM" | tee_root "/sys/class/gpio/export"
  [[ -w "$GPIO_DIR/direction" ]] && echo out | tee_root "$GPIO_DIR/direction"
}

apply_mcu_led() {
  local name="$1"
  [[ "$name" == "off" ]] && { ensure_gpio; echo 0 | tee_root "$GPIO_DIR/value"; save_state "$name"; return 0; }
  
  local code="${MCU_MODES[$name]:-}"
  [[ -z "$code" ]] && return 1
  
  ensure_gpio
  echo 1 | tee_root "$GPIO_DIR/value"
  
  if "$MCU_LED_BIN" "$UART_DEV" chgmode "$code" 1 2>/dev/null; then
    save_state "$name"
  else
    dialog --msgbox "Failed: $name" 6 34 > "$CURR_TTY"; return 1
  fi
}

# ==================== Backend: gpio ====================
led_off_all() {
  for led in "$LED_BLUE" "$LED_GREEN" "$LED_RED"; do
    [[ -w "$led" ]] && echo 0 | sudo tee "$led" >/dev/null
  done
}

led_set_bgr() {
  local b="$1" g="$2" r="$3"
  [[ -w "$LED_BLUE"  ]] && echo "$b" | sudo tee "$LED_BLUE" >/dev/null
  [[ -w "$LED_GREEN" ]] && echo "$g" | sudo tee "$LED_GREEN" >/dev/null
  [[ -w "$LED_RED"   ]] && echo "$r" | sudo tee "$LED_RED" >/dev/null
}

get_max_brightness() {
  local node="$1" max="${node%/brightness}/max_brightness"
  [[ -r "$max" ]] && cat "$max" || echo 1
}

apply_gpio() {
  local name="$1"
  
  # 禁用触发器
  for t in /sys/class/leds/*/trigger; do
    [[ -w "$t" ]] && echo none | sudo tee "$t" >/dev/null
  done
  
  local B G R
  B="$(get_max_brightness "$LED_BLUE")"
  G="$(get_max_brightness "$LED_GREEN")"
  R="$(get_max_brightness "$LED_RED")"
  
  case "$name" in
    off)    led_off_all ;;
    green)  led_set_bgr 0 "$G" 0 ;;
    blue)   led_set_bgr "$B" 0 0 ;;
    red)    led_set_bgr 0 0 "$R" ;;
    white)  led_set_bgr "$B" "$G" "$R" ;;
    orange|yellow) led_set_bgr 0 "$G" "$R" ;;
    purple) led_set_bgr "$B" 0 "$R" ;;
    *)      return 1 ;;
  esac
  
  save_state "$name"
}

# ==================== Backend: ws2812 ====================
declare -A WS2812_MODES=(
  [off]=OFF [scrolling]=Scrolling [breathing]=Breathing
  [breathing_red]=Breathing_Red [breathing_green]=Breathing_Green [breathing_blue]=Breathing_Blue
  [breathing_blue_red]=Breathing_Blue_Red [breathing_green_blue]=Breathing_Green_Blue
  [breathing_red_green]=Breathing_Red_Green [breathing_red_green_blue]=Breathing_Red_Green_Blue
  [red_green_blue]=Red_Green_Blue [blue_red]=Blue_Red [blue]=Blue
  [green_blue]=Green_Blue [green]=Green [red_green]=Red_Green [red]=Red
)

kill_ws2812() {
  pkill -f "^${WS2812CTL_BIN}" >/dev/null 2>&1 || true
}

apply_ws2812() {
  local name="$1" arg="${WS2812_MODES[$name]:-}"
  [[ -z "$arg" ]] && return 1
  
  kill_ws2812
  [[ "$arg" == "OFF" ]] || nohup "$WS2812CTL_BIN" "$arg" >/dev/null 2>&1 </dev/null &
  sleep 0.1
  
  save_state "$name"
}

# ==================== 统一应用接口 ====================
apply_choice() {
  local name="$1"
  case "$LED_TYPE" in
    mcu_led) apply_mcu_led "$name" ;;
    gpio)    apply_gpio "$name" ;;
    ws2812)  apply_ws2812 "$name" ;;
    *)       return 1 ;;
  esac
}

# ==================== 后端检查 ====================
backend_precheck() {
  case "$LED_TYPE" in
    mcu_led) [[ -x "$MCU_LED_BIN" ]] || fatal_msg "mcu_led not found:\n$MCU_LED_BIN" ;;
    ws2812)  [[ -x "$WS2812CTL_BIN" ]] || fatal_msg "ws2812 not found:\n$WS2812CTL_BIN" ;;
  esac
}

# ==================== 退出处理 ====================
cleanup() {
  printf "\033c\e[?25h" > "$CURR_TTY"
  pkill -f "gptokeyb.*joyled" >/dev/null 2>&1 || true
}
trap cleanup EXIT SIGINT SIGTERM

# ==================== UI 初始化 ====================
init_ui() {
  printf "\033c\e[?25l" > "$CURR_TTY"
  [[ -f "$CONSOLE_FONT" ]] && setfont "$CONSOLE_FONT" 2>/dev/null || true
  
  if [[ -x "$GPTOKEYB_BIN" ]]; then
    [[ -e /dev/uinput ]] && chmod 666 /dev/uinput 2>/dev/null || true
    export SDL_GAMECONTROLLERCONFIG_FILE="$SDL_DB_PATH"
    pkill -f "gptokeyb.*joyled" >/dev/null 2>&1 || true
    "$GPTOKEYB_BIN" -1 "joyled.sh" -c "$KEYS_GPTK_PATH" >/dev/null 2>&1 &
  fi
}

# ==================== 主菜单 ====================
show_menu() {
  local items opts
  items="$(get_menu_items "$LED_TYPE")"
  opts=()
  
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local tag="${line%%:*}" desc="${line#*:}"
    opts+=("$tag" "$desc")
  done <<< "$items"
  
  local default=""
  [[ -n "$LAST_CHOICE" && $(choice_valid "$LAST_CHOICE" "$LED_TYPE") ]] && default="--default-item $LAST_CHOICE"
  
  dialog $default --output-fd 1 \
    --backtitle "Joystick LED - Model: ${DEVICE_NAME} | Backend: ${LED_TYPE}" \
    --title "LED Mode" --menu "Select LED color/effect" 20 60 12 "${opts[@]}" 2>"$CURR_TTY" || true
}

main_menu() {
  while true; do
    local choice; choice="$(show_menu)"
    [[ -z "$choice" ]] && exit 0
    
    if apply_choice "$choice"; then
      LAST_CHOICE="$choice"
    fi
  done
}

# ==================== CLI 接口 ====================
cli_apply() {
  local color; color="$(load_saved_color)" || { echo "No saved color" > "$CURR_TTY"; exit 1; }
  apply_choice "$color"
}

cli_set() {
  local color="${1:-}"
  [[ -z "$color" ]] && { echo "Usage: $0 --set <color>" > "$CURR_TTY"; exit 1; }
  apply_choice "$color"
}

# ==================== 主函数 ====================
main() {
  detect_device
  
  # 未支持机型
  if [[ "$LED_TYPE" == "unsupported" ]]; then
    fatal_msg "Unsupported device:\n$DEVICE_NAME\nLED Type: $LED_TYPE"
  fi
  
  backend_precheck
  init_ui
  load_last_choice
  
  # CLI 模式
  case "${1:-}" in
    --apply) cli_apply; exit $? ;;
    --set)   cli_set "${2:-}"; exit $? ;;
  esac
  
  # 交互模式
  printf "Joystick LED Controller\nModel: %s | Backend: %s\n" "$DEVICE_NAME" "$LED_TYPE" > "$CURR_TTY"
  sleep 0.25
  main_menu
}

main "$@"