#!/usr/bin/env bash
set -euo pipefail

# =============== 路径配置（可按需调整）===============
QUIRKS_DIR="/home/ark/.quirks"     # 目标机型库
CONSOLE_FILE="/boot/.console"      # 当前生效机型标记
JOYLED_FILE="/home/ark/.joyled"    # joyled配置记录
JOYLED_BIN="/opt/system/Clone/joyled.sh"

# =============== 小工具函数（英文输出 / 中文注释）===============
LOG_FILE="/boot/clone_log.txt"
# 每次开机先清空一次，避免一直追加
: > "$LOG_FILE" 2>/dev/null || true
msg()  { echo "[clone.sh] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[clone.sh][WARN] $*" | tee -a "$LOG_FILE" >&2; }
err()  { echo "[clone.sh][ERR ] $*" | tee -a "$LOG_FILE" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# =============== OTA：开机自动检测并执行 /roms/update.tar ===============
maybe_apply_ota_update() {
  local tar_path=""
  local tmpdir="/home/ark/.ota_update"
  local TTY="/dev/tty1"

  if [[ -f "/roms/update.tar" ]]; then
    tar_path="/roms/update.tar"
  elif [[ -f "/roms2/update.tar" ]]; then
    tar_path="/roms2/update.tar"
  else
    return 0
  fi

  msg "OTA package found: $tar_path"

  sudo rm -rf "$tmpdir" 2>/dev/null || true
  sudo mkdir -p "$tmpdir" || { err "Failed to create OTA dir: $tmpdir"; return 0; }

  {
    printf '\033c' 2>/dev/null || true
    echo "==============================="
    echo "        ArkOS4Clone OTA        "
    echo "==============================="
    echo
    echo "[OTA] Package:"
    echo "  $tar_path"
    echo
    echo "[OTA] Workdir:"
    echo "  $tmpdir"
    echo
    echo "[OTA] Step 1/2: Extracting minimal files"
    echo "[OTA] (Do NOT power off)"
    echo
  } > "$TTY"

  msg "OTA extracting minimal to: $tmpdir"

  # 只解最小：VERSION + install.sh + CHUNKS + META
  if tar --help 2>/dev/null | grep -q -- '--checkpoint'; then
    if ! sudo tar -xf "$tar_path" -C "$tmpdir" \
        VERSION install.sh CHUNKS META \
        --checkpoint=200 \
        --checkpoint-action=exec='sh -c "echo \"[OTA] extracting... ($TAR_CHECKPOINT files)\""' \
        2>&1 | tee -a "$LOG_FILE" > "$TTY"; then
      err "OTA extract failed"
      echo "[OTA] Extract FAILED. See $LOG_FILE" > "$TTY"
      sudo rm -rf "$tmpdir" 2>/dev/null || true
      return 0
    fi
  else
    echo "[OTA] extracting... please wait." > "$TTY"
    if ! sudo tar -xf "$tar_path" -C "$tmpdir" \
         VERSION install.sh CHUNKS META \
         2>&1 | tee -a "$LOG_FILE" >> "$TTY"; then
      err "OTA extract failed"
      echo "[OTA] Extract FAILED. See $LOG_FILE" > "$TTY"
      sudo rm -rf "$tmpdir" 2>/dev/null || true
      return 0
    fi
  fi

  {
    echo
    echo "[OTA] Step 1/2: Extract OK"
    echo
    echo "[OTA] Step 2/2: Running install.sh"
    echo
  } > "$TTY"

  [[ -f "$tmpdir/install.sh" ]] || { err "install.sh not found"; echo "[OTA] install.sh NOT FOUND" > "$TTY"; sudo rm -rf "$tmpdir" 2>/dev/null || true; return 0; }

  sudo chmod +x "$tmpdir/install.sh" 2>/dev/null || true

  if ! sudo env OTA_TAR_PATH="$tar_path" LOG_FILE="$LOG_FILE" bash "$tmpdir/install.sh" \
       2>&1 | tee -a "$LOG_FILE" >> "$TTY"; then
    err "OTA install failed"
    echo "[OTA] Install FAILED. See $LOG_FILE" >> "$TTY"
    sudo rm -rf "$tmpdir" 2>/dev/null || true
    return 0
  fi

  sudo rm -f "$tar_path" 2>/dev/null || true
  sudo rm -rf "$tmpdir" 2>/dev/null || true
  sudo rm -rf /boot/.console 2>/dev/null || true
  sync || true

  {
    echo
    echo "[OTA] SUCCESS"
    echo "[OTA] Update package removed"
    for i in {30..1}; do
      echo "[OTA] Powering off in ${i}s... Please remove the SD card and re-run DTB_SELECTOR."
      sleep 1
    done
  } >> "$TTY"

  msg "OTA applied successfully, powering off"
  sleep 2
  poweroff -f || true
  exit 0
}

# 读当前 .console 内容，小工具函数，避免重复
get_console_label() {
  tr -d '\r\n' < "$CONSOLE_FILE" 2>/dev/null || true
}

get_joyled_model() {
  [[ -r "$JOYLED_FILE" ]] || return 1
  local line
  line="$(grep -E '^MODEL=' "$JOYLED_FILE" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  echo "${line#MODEL=}"
}

apply_joyled_if_match() {
  # 只在机型匹配时应用，且失败不影响开机
  if [[ -x "$JOYLED_BIN" ]]; then
    msg "Applying saved joyled via: $JOYLED_BIN --apply"
    bash "$JOYLED_BIN" --apply >>"$LOG_FILE" 2>&1 || warn "joyled --apply failed"
  else
    warn "joyled binary not found or not executable: $JOYLED_BIN"
  fi
}

joyled_boot_flow() {
  [[ -f "$JOYLED_FILE" ]] || return 0

  local saved
  saved="$(get_joyled_model || true)"

  # 文件坏了：删
  if [[ -z "${saved:-}" ]]; then
    warn "joyled file exists but MODEL missing, removing: $JOYLED_FILE"
    rm -f "$JOYLED_FILE" 2>/dev/null || true
    return 0
  fi

  # 机型不一致：删
  if [[ "$saved" != "$LABEL" ]]; then
    msg "joyled model mismatch: saved=$saved current=$LABEL -> removing $JOYLED_FILE"
    rm -f "$JOYLED_FILE" 2>/dev/null || true
    return 0
  fi

  # 机型一致：应用
  apply_joyled_if_match
}

# 先读取已有 .console，r36s作为默认机型
CUR_VAL="$(get_console_label)"
DEFAULT_LABEL="${CUR_VAL:-r36s}"

# =============== DTB -> LABEL 映射（按你的表）===============
# 从 /boot/boot.ini 中匹配：load mmc 1:1 ${dtb_loadaddr} <DTB>
BOOTINI="/boot/boot.ini"
DTB=""

if [[ -r "$BOOTINI" ]]; then
  # 容忍失败：整条管道最后加 || true
  DTB="$(
    grep -oE 'load[[:space:]]+mmc[[:space:]]+1:1[[:space:]]+\$\{dtb_loadaddr\}[[:space:]]+[[:graph:]]+' "$BOOTINI" \
    | awk '{print $NF}' \
    | tail -n1 \
    | xargs -r basename \
    || true
  )"
  msg "boot.ini readable, parsed DTB='${DTB:-<empty>}'"
else
  warn "boot.ini not readable: $BOOTINI"
fi

declare -A dtb2label=(
  [rk3326-mymini-linux.dtb]=mymini
  [rk3326-mini40-linux.dtb]=mini40
  [rk3326-xf35h-linux.dtb]=xf35h
  [rk3326-r36pro-linux.dtb]=r36pro
  [rk3326-r36max-linux.dtb]=r36max
  [rk3326-xf40h-linux.dtb]=xf40h
  [rk3326-dc40v-linux.dtb]=dc40v
  [rk3326-dc35v-linux.dtb]=dc35v
  [rk3326-r36max2-linux.dtb]=r36max2
  [rk3326-r36h-linux.dtb]=r36h
  [rk3326-r36plus-linux.dtb]=r36splus
  [rk3326-r46h-linux.dtb]=r46h
  [rk3326-r40xx-linux.dtb]=r40xx
  [rk3326-hg36-linux.dtb]=hg36
  [rk3326-rx6h-linux.dtb]=rx6h
  [rk3326-k36s-linux.dtb]=k36s
  [rk3326-r36tmax-linux.dtb]=r36tmax
  [rk3326-t16max-linux.dtb]=t16max
  [rk3326-r36ultra-linux.dtb]=r36ultra
  [rk3326-xgb36-linux.dtb]=xgb36
  [rk3326-a10mini-linux.dtb]=a10mini
  [rk3326-a10mini-v2-linux.dtb]=a10miniv2
  [rk3326-g350-linux.dtb]=g350
  [rk3326-u8-linux.dtb]=u8
  [rk3326-u8-v2-linux.dtb]=u8
  [rk3326-dr28s-linux.dtb]=dr28s
  [rk3326-d007-linux.dtb]=d007
  [rk3326-r50s-linux.dtb]=r50s
  [rk3326-rgb20s-linux.dtb]=rgb20s
  [rk3326-xf28-linux.dtb]=xf28
)

declare -A console_profile=(
  [mymini]=480p
  [mini40]=480p
  [xf35h]=480p
  [r36pro]=480p
  [r36max]=720p
  [xf40h]=720p
  [dc40v]=720p
  [dc35v]=480p
  [r36max2]=768p
  [r36h]=480p
  [r36splus]=720p
  [r46h]=768p
  [r40xx]=768p
  [hg36]=480p
  [rx6h]=480p
  [k36s]=480p
  [r36tmax]=720p
  [t16max]=720p
  [r36ultra]=720p
  [xgb36]=480p
  [a10mini]=480p
  [a10miniv2]=540p
  [g350]=480p
  [u8]=800p480
  [dr28s]=480p
  [d007]=480p
  [r50s]=854p480
  [rgb20s]=480p
  [xf28]=480p
  [r36s]=480p
)

declare -A joy_conf_map=(
  [mymini]=single
  [mini40]=single
  [xf35h]=dual
  [r36pro]=dual
  [r36max]=dual
  [xf40h]=dual
  [dc40v]=dual
  [dc35v]=dual
  [r36max2]=dual
  [r36h]=dual
  [r36splus]=dual
  [r46h]=dual
  [r40xx]=dual
  [hg36]=dual
  [rx6h]=dual
  [k36s]=single
  [r36tmax]=dual
  [t16max]=dual
  [r36ultra]=dual
  [xgb36]=single
  [a10mini]=none
  [a10miniv2]=none
  [g350]=dual
  [u8]=dual
  [dr28s]=none
  [d007]=dual
  [r50s]=dual
  [rgb20s]=dual
  [xf28]=single
  [r36s]=dual
)

declare -A ogage_conf_map=(
  [mymini]=select
  [mini40]=select
  [xf35h]=select
  [r36pro]=happy5
  [r36max]=happy5
  [xf40h]=select
  [dc40v]=happy5
  [dc35v]=happy5
  [r36max2]=happy5
  [r36h]=select
  [r36splus]=happy5
  [r46h]=select
  [r40xx]=happy5
  [hg36]=happy5
  [rx6h]=select
  [k36s]=happy5
  [r36tmax]=happy5
  [t16max]=happy5
  [r36ultra]=happy5
  [xgb36]=happy5
  [a10mini]=happy5
  [a10miniv2]=happy5
  [g350]=happy5
  [u8]=happy5
  [dr28s]=happy5
  [d007]=select
  [r50s]=happy5
  [rgb20s]=happy5
  [xf28]=select
  [r36s]=happy5
)

declare -A rotate_map=(
  [u8]=270
  [dr28s]=270
  [r50s]=270
  [a10miniv2]=180
  [xf28]=90
)

spi_set=("dc35v" "dc40v" "xf28" "r36max2")                                               # 按需增删

# LABEL：优先用 DTB 映射；没有映射就退回 r36s
LABEL="${dtb2label[$DTB]:-r36s}"

# 如果源存在则复制；isfile=yes 时以文件目标安装（保持权限 0755）
cp_if_exists() {
  local src="$1" dst="$2" isfile="${3:-no}"

  if [[ -e "$src" ]]; then
    if [[ "$isfile" == "yes" ]]; then
      mkdir -p "$(dirname "$dst")"
      # 保留属主/属组/时间戳等
      if cp -a "$src" "$dst" 2>/dev/null; then
        :
      else
        # 极端情况下的兜底：还用 install，但把所有权按源文件纠正回去
        install -m 0755 -D "$src" "$dst"
        sudo chown --reference="$src" "$dst" 2>/dev/null || true
        sudo touch -r "$src" "$dst" 2>/dev/null || true
      fi
      # 统一权限为 0755（不影响属主/属组）
      sudo chmod 0755 "$dst" || true
    else
      mkdir -p "$dst"
      cp -a "$src" "$dst/"
    fi
    msg "Copied: $src -> $dst"
  else
    warn "Source not found, skip: $src"
  fi
}

link_drastic_dir() {
  local name="$1"
  local src="/roms/nds/$name"
  local dst="/opt/drastic/$name"

  # 如果源目录不存在则创建一个空目录
  if [[ ! -d "$src" ]]; then
    msg "Source $src not found, creating it..."
    sudo mkdir -p "$src" || warn "Failed to create $src"
  fi

  # 删除旧的目录或符号链接（不让失败导致脚本退出）
  if [[ -e "$dst" || -L "$dst" ]]; then
    msg "Remove old $dst"
    sudo rm -rf "$dst" || warn "Failed to remove $dst"
  fi

  # 创建新的符号链接
  if sudo ln -s "$src" "$dst"; then
    msg "Linked: $dst -> $src"
  else
    warn "Failed to create symlink: $dst -> $src"
  fi
}

apply_hotkey_conf() {
  local dtbval="$1" kind ogage_conf ra_conf ra32_conf
  # 键不存在时，kind 为空串（避免 set -u 爆炸）
  kind="${ogage_conf_map[$dtbval]:-}"

  case "$kind" in
    select)
      ogage_conf="$QUIRKS_DIR/ogage.select.conf"
      ra_conf="$QUIRKS_DIR/retroarch64.cfg"
      ra32_conf="$QUIRKS_DIR/retroarch32.cfg"
      ;;
    happy5)
      ogage_conf="$QUIRKS_DIR/ogage.happy5.conf"
      ra_conf="$QUIRKS_DIR/retroarch64.cfg"
      ra32_conf="$QUIRKS_DIR/retroarch32.cfg"
      ;;
    *)
      ogage_conf=""
      ra_conf=""
      ra32_conf=""
      ;;
  esac

  if [[ -n "$ogage_conf" ]]; then
    msg "change hotkey: $dtbval -> $(basename "$ogage_conf")"
    cp_if_exists "$ogage_conf" "/home/ark/ogage.conf" "yes"
  else
    msg "hotkey unchanged for: $dtbval (no mapping)"
  fi

  if [[ -n "$ra_conf" ]]; then
    msg "change hotkey: $dtbval -> $(basename "$ra_conf")"
    cp_if_exists "$ra_conf" "/home/ark/.config/retroarch/retroarch.cfg" "yes"
  else
    msg "hotkey unchanged for: $dtbval (no mapping)"
  fi

  if [[ -n "$ra32_conf" ]]; then
    msg "change hotkey: $dtbval -> $(basename "$ra32_conf")"
    cp_if_exists "$ra32_conf" "/home/ark/.config/retroarch32/retroarch.cfg" "yes"
  else
    msg "hotkey unchanged for: $dtbval (no mapping)"
  fi
}

adjust_per_joy_conf() {
  local dtbval="$1" prof
  # 键不存在时，prof 为空串（避免 set -u 爆炸）
  prof="${joy_conf_map[$dtbval]:-}"

  case "$prof" in
    none|single)
      cp_if_exists "$QUIRKS_DIR/noneJoy/controls.ini"     "/roms/psp/ppsspp/PSP/SYSTEM/controls.ini"       "yes"
      cp_if_exists "$QUIRKS_DIR/noneJoy/ppsspp.ini"       "/roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini"         "yes"
      cp_if_exists "$QUIRKS_DIR/noneJoy/ppsspp.ini.sdl"   "/roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl"     "yes"
      [[ -d "/roms2/psp" ]] && cp_if_exists "$QUIRKS_DIR/noneJoy/controls.ini"   "/roms2/psp/ppsspp/PSP/SYSTEM/controls.ini"   "yes" || true
      [[ -d "/roms2/psp" ]] && cp_if_exists "$QUIRKS_DIR/noneJoy/ppsspp.ini"     "/roms2/psp/ppsspp/PSP/SYSTEM/ppsspp.ini"     "yes" || true
      [[ -d "/roms2/psp" ]] && cp_if_exists "$QUIRKS_DIR/noneJoy/ppsspp.ini.sdl" "/roms2/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl" "yes" || true
      ;;
    dual)
      cp_if_exists "$QUIRKS_DIR/dualJoy/controls.ini"     "/roms/psp/ppsspp/PSP/SYSTEM/controls.ini"       "yes"
      cp_if_exists "$QUIRKS_DIR/dualJoy/ppsspp.ini"       "/roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini"         "yes"
      cp_if_exists "$QUIRKS_DIR/dualJoy/ppsspp.ini.sdl"   "/roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl"     "yes"
      [[ -d "/roms2/psp" ]] && cp_if_exists "$QUIRKS_DIR/dualJoy/controls.ini"   "/roms2/psp/ppsspp/PSP/SYSTEM/controls.ini"   "yes" || true
      [[ -d "/roms2/psp" ]] && cp_if_exists "$QUIRKS_DIR/dualJoy/ppsspp.ini"     "/roms2/psp/ppsspp/PSP/SYSTEM/ppsspp.ini"     "yes" || true
      [[ -d "/roms2/psp" ]] && cp_if_exists "$QUIRKS_DIR/dualJoy/ppsspp.ini.sdl" "/roms2/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl" "yes" || true
      ;;
    *)
      msg "No profile assets for: ${prof:-<empty>} (dtbval=$dtbval)"
      ;;
  esac
}

apply_profile_assets() {
  local cur prof
  cur="$(get_console_label)"
  [[ -n "$cur" ]] || return 0

  prof="${console_profile[$cur]:-}"
  if [[ -n "$prof" ]]; then
    msg "Applying 351Files profile: $prof (console=$cur)"
    cp_if_exists "$QUIRKS_DIR/$prof/351Files" "/opt/351Files" "no"
  else
    msg "No profile assets for: $cur"
  fi
}

apply_es_input() {
  [[ -f "$CONSOLE_FILE" ]] || return 0
  cp_if_exists "$QUIRKS_DIR/retroarch64.cfg" "/home/ark/.config/retroarch/retroarch.cfg" "yes"
  cp_if_exists "$QUIRKS_DIR/retroarch32.cfg" "/home/ark/.config/retroarch32/retroarch.cfg" "yes"
  cp_if_exists "$QUIRKS_DIR/es_input.cfg" "/etc/emulationstation/es_input.cfg" "yes"
  sed -i -e '/menu_driver \= \"/c\menu_driver \= \"ozone\"' /home/ark/.config/retroarch32/retroarch.cfg        || true
  sed -i -e '/menu_driver \= \"/c\menu_driver \= \"ozone\"' /home/ark/.config/retroarch/retroarch.cfg          || true
  sed -i -e '/menu_driver \= \"/c\menu_driver \= \"ozone\"' /home/ark/.config/retroarch32/retroarch.cfg.bak    || true
  sed -i -e '/menu_driver \= \"/c\menu_driver \= \"ozone\"' /home/ark/.config/retroarch/retroarch.cfg.bak      || true
}

apply_rotate_file() {
  local dtbval="$1"
  local prof="${rotate_map[$dtbval]:-0}"
  msg "apply_rotate_file: console=$dtbval rotation=$prof"
  case "$prof" in
    270)
      msg "Using SDL=rotate270 + RetroArch=270 for console=$dtbval"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/32/libSDL2-2.0.so.0.3200.10.rotate270" "/usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10" "yes"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/64/libSDL2-2.0.so.0.3200.10.rotate270" "/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10" "yes"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2.so /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (64)"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10 /usr/lib/aarch64-linux-gnu/libSDL2.so || warn "ln failed: libSDL2.so (64)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2.so /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (32)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10 /usr/lib/arm-linux-gnueabihf/libSDL2.so || warn "ln failed: libSDL2.so (32)"

      cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch32.270" "/opt/retroarch/bin/retroarch32" "yes"
	    cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch.270" "/opt/retroarch/bin/retroarch" "yes"
      ;;
    180)
      msg "Using SDL=rotate180 + RetroArch=180 for console=$dtbval"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/32/libSDL2-2.0.so.0.3200.10.rotate180" "/usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10" "yes"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/64/libSDL2-2.0.so.0.3200.10.rotate180" "/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10" "yes"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2.so /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (64)"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10 /usr/lib/aarch64-linux-gnu/libSDL2.so || warn "ln failed: libSDL2.so (64)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2.so /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (32)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10 /usr/lib/arm-linux-gnueabihf/libSDL2.so || warn "ln failed: libSDL2.so (32)"

      cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch32.180" "/opt/retroarch/bin/retroarch32" "yes"
	    cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch.180" "/opt/retroarch/bin/retroarch" "yes"
      ;;
    90)
      msg "Using SDL=rotate90 + RetroArch=90 for console=$dtbval"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/32/libSDL2-2.0.so.0.3200.10.rotate90" "/usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10" "yes"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/64/libSDL2-2.0.so.0.3200.10.rotate90" "/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10" "yes"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2.so /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (64)"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10 /usr/lib/aarch64-linux-gnu/libSDL2.so || warn "ln failed: libSDL2.so (64)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2.so /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (32)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10 /usr/lib/arm-linux-gnueabihf/libSDL2.so || warn "ln failed: libSDL2.so (32)"

      cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch32.90" "/opt/retroarch/bin/retroarch32" "yes"
	    cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch.90" "/opt/retroarch/bin/retroarch" "yes"
      ;;
    *)
      msg "Using SDL=0deg + RetroArch=0deg for console=$dtbval"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/32/libSDL2-2.0.so.0.3200.10.norotate" "/usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10" "yes"
      cp_if_exists "$QUIRKS_DIR/rotate/sdl2/64/libSDL2-2.0.so.0.3200.10.norotate" "/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10" "yes"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2.so /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (64)"
      sudo ln -sfv /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.3200.10 /usr/lib/aarch64-linux-gnu/libSDL2.so || warn "ln failed: libSDL2.so (64)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2.so /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0 || warn "ln failed: libSDL2-2.0.so.0 (32)"
      sudo ln -sfv /usr/lib/arm-linux-gnueabihf/libSDL2-2.0.so.0.3200.10 /usr/lib/arm-linux-gnueabihf/libSDL2.so || warn "ln failed: libSDL2.so (32)"

      cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch32.norotate" "/opt/retroarch/bin/retroarch32" "yes"
	    cp_if_exists "$QUIRKS_DIR/rotate/retroarch/retroarch.norotate" "/opt/retroarch/bin/retroarch" "yes"
      ;;
  esac
  sudo chmod 777 /opt/retroarch/bin/* || true
}

# 依据 LABEL 执行
apply_quirks_for() {
  local dtbval="$1"
  msg "apply_quirks_for: LABEL=$dtbval"
  adjust_per_joy_conf "$dtbval"
  apply_hotkey_conf "$dtbval"
  apply_profile_assets
  apply_es_input
  apply_rotate_file "$dtbval"
}

# =============== 执行开始 ===============
msg "DTB filename: ${DTB:-<empty>}, LABEL: $LABEL"
maybe_apply_ota_update
# 按规则处理 /boot/.console
if [[ ! -f "$CONSOLE_FILE" ]]; then
  printf '\033c'
  echo "==============================="
  echo "   arkos for clone lcdyk  ..."
  echo "==============================="
  sleep 2
  link_drastic_dir backup
  link_drastic_dir cheats
  link_drastic_dir savestates
  link_drastic_dir slot2
  echo "$LABEL" | sudo tee "$CONSOLE_FILE" > /dev/null || warn "Failed to write $CONSOLE_FILE"
  msg "First boot for clone script, initial LABEL=$LABEL"
  msg "Wrote new console file: $CONSOLE_FILE -> $LABEL"
  apply_quirks_for "$LABEL"
  sleep 5
  systemctl status systemd-journald.service systemd-journald.socket || true
  sudo systemctl unmask systemd-journald.service systemd-journald.socket || true
  sudo systemctl enable --now systemd-journald.service systemd-journald.socket || true
else
  CUR_VAL="$(get_console_label)"
  if [[ "$CUR_VAL" == "$LABEL" ]]; then
    msg "Console unchanged ($CUR_VAL); nothing to do."
  else
    msg "Console change requested: old=${CUR_VAL:-<none>} new=$LABEL"
    (
      # ==== 所有输出都到 tty1 ====
      # 复位/清屏并回到左上角
      printf '\033c'
      echo "==============================="
      echo "   arkos for clone lcdyk  ..."
      echo "==============================="
      echo
      echo "[firstboot.sh] old config: ${CUR_VAL}"
      echo "[firstboot.sh] new config: ${LABEL}"
      echo
      # 顺序保持不变：先写 .console，再应用 quirks（避免重入时再次触发）
      echo "$LABEL" | sudo tee "$CONSOLE_FILE" > /dev/null
      apply_quirks_for "$LABEL"
      sleep 5
    ) > /dev/tty1 2>&1
    systemctl status systemd-journald.service systemd-journald.socket || true
    sudo systemctl unmask systemd-journald.service systemd-journald.socket || true
    sudo systemctl enable --now systemd-journald.service systemd-journald.socket || true
  fi
fi

# 加载驱动
sudo depmod -a || true

# ws2812 摇杆灯控制加载 spi 模块
if [[ -f "$CONSOLE_FILE" ]]; then
  cur_console="$(get_console_label)"
  for x in "${spi_set[@]}"; do
    if [[ "$cur_console" == "$x" ]]; then
      msg "sudo modprobe spidev : $cur_console"
      sudo modprobe spidev || true
      break
    fi
  done
fi

# 开机将音频设置为 SPK 如果是 OFF 的话
STATE="$(
  amixer get 'Playback Path' 2>/dev/null | grep -oP "Item0: '\K\w+" || true
)"

if [[ "$STATE" = "OFF" || "$STATE" = "HP" ]]; then
  echo "Playback Path is OFF, switching to SPK..."
  amixer set 'Playback Path' 'SPK' || true
  sudo alsactl store || true
else
  echo "Playback Path is already set to ${STATE:-UNKNOWN}, no change."
fi

cp_if_exists "$QUIRKS_DIR/.asoundrc"     "/home/ark/.asoundrc"       "yes"

# D007: 动态启用 / 禁用 adckeys.service
if [[ -f "$CONSOLE_FILE" ]]; then
  cur_console="$(get_console_label)"

  if [[ "$cur_console" == "d007" ]]; then
    msg "Detected D007 -> enabling adckeys.service"
    sudo systemctl daemon-reload || warn "daemon-reload failed"
    sudo systemctl enable --now adckeys.service \
      || warn "failed to enable/start adckeys.service"
  else
    msg "Not D007 -> disabling adckeys.service (if exists)"
    { sudo systemctl disable --now adckeys.service; } >/dev/null 2>&1 || true
  fi
fi

# 简体中文配置
if [[ -f "/boot/.cn" ]]; then
  msg "Apply first-boot zh-CN localization"
  if grep -q "Language" /home/ark/.emulationstation/es_settings.cfg; then
    sed -i -e '/<string name\=\"Language/c\<string name\=\"Language\" value\=\"zh-CN\" \/>' /home/ark/.emulationstation/es_settings.cfg || true
  else
    sed -i '$a <string name\=\"Language\" value\=\"zh-CN\" \/>' /home/ark/.emulationstation/es_settings.cfg || true
  fi

  cp_if_exists "$QUIRKS_DIR/option-gamelist.xml" "/opt/system/gamelist.xml" "yes"
  sudo rm -f /etc/localtime || true
  sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true

  sudo sed -i -e '/Language \= en_US/c\Language \= zh_CN' /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini      || true
  sudo sed -i -e '/Language \= en_US/c\Language \= zh_CN' /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.go   || true
  sudo sed -i -e '/Language \= en_US/c\Language \= zh_CN' /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl  || true

  sed -i -e '/Language \= en_US/c\Language \= zh_CN' /roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini      || true
  sed -i -e '/Language \= en_US/c\Language \= zh_CN' /roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.go   || true
  sed -i -e '/Language \= en_US/c\Language \= zh_CN' /roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl  || true

  sed -i -e '/user_language \= \"/c\user_language \= \"12\"' /home/ark/.config/retroarch32/retroarch.cfg        || true
  sed -i -e '/user_language \= \"/c\user_language \= \"12\"' /home/ark/.config/retroarch/retroarch.cfg          || true
  sed -i -e '/user_language \= \"/c\user_language \= \"12\"' /home/ark/.config/retroarch32/retroarch.cfg.bak    || true
  sed -i -e '/user_language \= \"/c\user_language \= \"12\"' /home/ark/.config/retroarch/retroarch.cfg.bak      || true

  sudo rm -f /boot/.cn || true

elif [[ -f "/boot/.ko" ]]; then
    msg "Apply first-boot ko localization"
  if grep -q "Language" /home/ark/.emulationstation/es_settings.cfg; then
    sed -i -e '/<string name\=\"Language/c\<string name\=\"Language\" value\=\"ko\" \/>' /home/ark/.emulationstation/es_settings.cfg || true
  else
    sed -i '$a <string name\=\"Language\" value\=\"ko\" \/>' /home/ark/.emulationstation/es_settings.cfg || true
  fi

  sudo rm -f /etc/localtime || true
  sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true

  sudo sed -i -e '/Language \= en_US/c\Language \= ko_KR' /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini      || true
  sudo sed -i -e '/Language \= en_US/c\Language \= ko_KR' /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.go   || true
  sudo sed -i -e '/Language \= en_US/c\Language \= ko_KR' /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl  || true

  sed -i -e '/Language \= en_US/c\Language \= ko_KR' /roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini      || true
  sed -i -e '/Language \= en_US/c\Language \= ko_KR' /roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.go   || true
  sed -i -e '/Language \= en_US/c\Language \= ko_KR' /roms/psp/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl  || true

  sed -i -e '/user_language \= \"/c\user_language \= \"10\"' /home/ark/.config/retroarch32/retroarch.cfg        || true
  sed -i -e '/user_language \= \"/c\user_language \= \"10\"' /home/ark/.config/retroarch/retroarch.cfg          || true
  sed -i -e '/user_language \= \"/c\user_language \= \"10\"' /home/ark/.config/retroarch32/retroarch.cfg.bak    || true
  sed -i -e '/user_language \= \"/c\user_language \= \"10\"' /home/ark/.config/retroarch/retroarch.cfg.bak      || true

  sudo rm -f /boot/.ko || true
fi

if [[ -x /home/ark/.config/lastgame.sh ]]; then
  sudo -u ark /home/ark/.config/lastgame.sh
fi
joyled_boot_flow
msg "Done. LABEL=$LABEL, CONSOLE_FILE=$(get_console_label)"
exit 0
