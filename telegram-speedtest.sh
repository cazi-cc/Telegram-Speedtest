#!/usr/bin/env bash
set -u

APP_NAME="telegram-speedtest"
APP_VERSION="0.7.0"
REPO_URL="https://github.com/cazi-cc/Telegram-Speedtest"
RAW_URL="https://raw.githubusercontent.com/cazi-cc/Telegram-Speedtest/main/telegram-speedtest.sh"
TDL_INSTALL_URL="https://docs.iyear.me/tdl/install.sh"

SHORTCUT_NAME="tst"
SHORTCUT_PATH="/usr/local/bin/${SHORTCUT_NAME}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${APP_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config"
SESSION_DIR="${HOME}/.tdl/${APP_NAME}"
TMP_ROOT="${TMPDIR:-/tmp}/${APP_NAME}-${UID:-0}-$$"
RESULT_FILE="${HOME}/${APP_NAME}-result.txt"
NAMESPACE="tst"
LOGIN_PROMPT_TIMEOUT="${TG_LOGIN_PROMPT_TIMEOUT:-10}"

TG_URL=""
PROXY=""
PROFILE_NAME="推荐低资源"
TEST_SECONDS=20
MULTI_THREADS=4
MULTI_POOL=4
LIMIT_MIB=128
KEEP_TDL=1
KEEP_TDL_USER_SET=0
LAST_SINGLE_MIBS=""
LAST_SINGLE_MBPS=""
LAST_MULTI_MIBS=""
LAST_MULTI_MBPS=""
CURRENT_TDL_PID=""
TDL_INSTALLED_BY_THIS_RUN=0
TDL_INSTALLED_PATH=""
NO_COLOR="${NO_COLOR:-0}"

if [ -t 1 ] && [ "$NO_COLOR" != "1" ]; then
  C_RESET="$(printf '\033[0m')"
  C_BOLD="$(printf '\033[1m')"
  C_DIM="$(printf '\033[2m')"
  C_BLUE="$(printf '\033[34m')"
  C_CYAN="$(printf '\033[36m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

print_origin() {
  cat <<EOF
${C_BOLD}${C_CYAN}Telegram-Speedtest${C_RESET} ${C_DIM}v${APP_VERSION}${C_RESET}
${C_DIM}基于 iyear/tdl 的 Telegram 资源测速封装，不是 Telegram 或 tdl 官方项目。${C_RESET}
${C_DIM}${REPO_URL}${C_RESET}
EOF
}

rule() {
  printf "%s\n" "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
}

clear_screen() {
  if [ -t 1 ]; then
    clear
  fi
}

section_title() {
  printf "\n%s%s%s\n" "$C_BOLD" "$1" "$C_RESET"
  rule
}

menu_item() {
  printf "  %s%2s%s  %s\n" "$C_GREEN" "$1" "$C_RESET" "$2"
}

status_line() {
  printf "  %s%-10s%s %s\n" "$C_DIM" "$1" "$C_RESET" "$2"
}

draw_progress() {
  local label="$1" elapsed="$2" seconds="$3" size="$4" limit_bytes="$5"
  local width=26
  local elapsed_pct size_pct pct filled empty bar
  elapsed_pct=$((elapsed * 100 / seconds))
  size_pct=$((size * 100 / limit_bytes))
  pct=$elapsed_pct
  [ "$size_pct" -gt "$pct" ] && pct="$size_pct"
  [ "$pct" -gt 100 ] && pct=100
  filled=$((pct * width / 100))
  empty=$((width - filled))
  bar="$(printf "%${filled}s" "" | tr ' ' '#')$(printf "%${empty}s" "" | tr ' ' '-')"
  printf "\r%s%-8s%s [%s%s%s] %3s%%  %s / %s  %ss/%ss" \
    "$C_CYAN" "$label" "$C_RESET" "$C_GREEN" "$bar" "$C_RESET" "$pct" \
    "$(human_size "$size")" "$(human_size "$limit_bytes")" "$elapsed" "$seconds" >&2
}

pause() {
  printf "\n按 Enter 返回..."
  read -r _ || true
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$SESSION_DIR" "$TMP_ROOT"
}

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  KEEP_TDL_USER_SET="${KEEP_TDL_USER_SET:-0}"
  if [ "$KEEP_TDL_USER_SET" != "1" ]; then
    KEEP_TDL=1
  fi
}

save_config() {
  ensure_dirs
  umask 077
  cat > "$CONFIG_FILE" <<EOF
TG_URL='$(printf "%s" "$TG_URL" | sed "s/'/'\\\\''/g")'
PROXY='$(printf "%s" "$PROXY" | sed "s/'/'\\\\''/g")'
PROFILE_NAME='$(printf "%s" "$PROFILE_NAME" | sed "s/'/'\\\\''/g")'
TEST_SECONDS='$TEST_SECONDS'
MULTI_THREADS='$MULTI_THREADS'
MULTI_POOL='$MULTI_POOL'
LIMIT_MIB='$LIMIT_MIB'
KEEP_TDL='$KEEP_TDL'
KEEP_TDL_USER_SET='$KEEP_TDL_USER_SET'
EOF
}

redact_proxy() {
  if [ -z "${1:-}" ]; then
    printf "直连"
    return
  fi
  printf "%s" "$1" | sed -E 's#(://)[^/@:]+(:[^/@]+)?@#\1***:***@#'
}

human_size() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB", u, " ");
    i=1;
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}

dir_size_bytes() {
  local path="$1"
  [ -e "$path" ] || { printf "0"; return; }
  if du -sb "$path" >/dev/null 2>&1; then
    du -sb "$path" | awk '{print $1}'
  else
    du -sk "$path" | awk '{print $1 * 1024}'
  fi
}

cleanup() {
  save_config >/dev/null 2>&1 || true
  if [ -n "${CURRENT_TDL_PID:-}" ] && kill -0 "$CURRENT_TDL_PID" >/dev/null 2>&1; then
    kill "$CURRENT_TDL_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$CURRENT_TDL_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
  if [ "$TDL_INSTALLED_BY_THIS_RUN" = "1" ] && [ "$KEEP_TDL" != "1" ] && [ -n "$TDL_INSTALLED_PATH" ]; then
    rm -f "$TDL_INSTALLED_PATH" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

install_shortcut() {
  local target="${1:-$SHORTCUT_PATH}"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -e
exec bash <(curl -fsSL "${RAW_URL}") "\$@"
EOF
  chmod 755 "$tmp"

  if [ "$(id -u)" = "0" ]; then
    mkdir -p "$(dirname "$target")"
    install -m 755 "$tmp" "$target"
    rm -f "$tmp"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$(dirname "$target")"
    sudo install -m 755 "$tmp" "$target"
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

run_as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

install_packages_if_possible() {
  local packages=""
  if command -v apt-get >/dev/null 2>&1; then
    packages="curl ca-certificates coreutils gawk sed"
    run_as_root apt-get update && run_as_root apt-get install -y $packages
  elif command -v dnf >/dev/null 2>&1; then
    packages="curl ca-certificates coreutils gawk sed"
    run_as_root dnf install -y $packages
  elif command -v yum >/dev/null 2>&1; then
    packages="curl ca-certificates coreutils gawk sed"
    run_as_root yum install -y $packages
  elif command -v zypper >/dev/null 2>&1; then
    packages="curl ca-certificates coreutils gawk sed"
    run_as_root zypper --non-interactive install $packages
  elif command -v pacman >/dev/null 2>&1; then
    packages="curl ca-certificates coreutils gawk sed"
    run_as_root pacman -Sy --noconfirm $packages
  elif command -v apk >/dev/null 2>&1; then
    packages="curl ca-certificates coreutils gawk sed"
    run_as_root apk add --no-cache $packages
  elif command -v pkg >/dev/null 2>&1; then
    packages="curl ca_root_nss coreutils gawk gsed"
    run_as_root pkg install -y $packages
  elif command -v brew >/dev/null 2>&1; then
    packages="curl coreutils gawk gnu-sed"
    brew install $packages
  else
    return 1
  fi
}

is_systemd_host() {
  command -v systemctl >/dev/null 2>&1 && command -v timedatectl >/dev/null 2>&1
}

get_ntp_sync_state() {
  if ! command -v timedatectl >/dev/null 2>&1; then
    printf "unknown"
    return
  fi
  local value
  value="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  case "$value" in
    yes|no) printf "%s" "$value" ;;
    *) printf "unknown" ;;
  esac
}

print_time_sync_status() {
  if ! command -v timedatectl >/dev/null 2>&1; then
    printf "当前系统没有 timedatectl，无法自动判断 NTP 时间同步状态。\n"
    return
  fi
  local synced service
  synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf "unknown")"
  service="$(timedatectl show -p NTP --value 2>/dev/null || printf "unknown")"
  printf "NTP 时间同步状态：NTPSynchronized=%s, NTP=%s\n" "${synced:-unknown}" "${service:-unknown}"
}

repair_time_sync() {
  if ! is_systemd_host; then
    cat <<EOF
当前系统没有检测到 systemd/timedatectl，脚本无法安全判断应使用哪种时间同步服务。
请手动启用 NTP/chrony/openntpd 后重试登录。
EOF
    return 1
  fi

  printf "将尝试启用系统时间同步。此操作用于修复 Telegram 登录卡在 Sending Code、二维码不返回或手机号登录无响应的问题。\n"
  printf "执行过程中可能会安装 systemd-timesyncd 或 chrony。\n"

  if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update || return 1
    run_as_root apt-get install -y systemd-timesyncd || return 1
    run_as_root systemctl enable --now systemd-timesyncd || return 1
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y chrony || return 1
    run_as_root systemctl enable --now chronyd || return 1
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y chrony || return 1
    run_as_root systemctl enable --now chronyd || return 1
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install chrony || return 1
    run_as_root systemctl enable --now chronyd || return 1
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --noconfirm systemd || true
    run_as_root systemctl enable --now systemd-timesyncd || return 1
  else
    run_as_root timedatectl set-ntp true || return 1
  fi

  run_as_root timedatectl set-ntp true >/dev/null 2>&1 || true
  sleep 2
  print_time_sync_status
}

prompt_time_sync_repair() {
  local reason="$1"
  printf "\n%sTelegram 登录时间同步检查%s\n" "$C_BOLD" "$C_RESET"
  rule
  printf "%s\n" "$reason"
  cat <<EOF
这个功能用于排查 tdl 登录 Telegram 时不返回二维码、手机号登录不继续、或卡在 Sending Code 的问题。
Telegram MTProto 登录依赖较准确的系统时间；如果 VPS 没启用 NTP 或时间偏差较大，认证请求可能被 Telegram 忽略。
EOF
  print_time_sync_status
  printf "\n是否现在尝试启用系统时间同步？不会自动修复，只有选择 y 才会执行。 [y/N]: "
  local answer
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES)
      repair_time_sync
      ;;
    *)
      printf "已跳过时间同步修复。你仍可继续重试登录。\n"
      ;;
  esac
}

pre_login_time_check() {
  local state
  state="$(get_ntp_sync_state)"
  if [ "$state" = "no" ]; then
    prompt_time_sync_repair "检测到系统时间未同步。建议先修复，否则 Telegram 登录可能不返回二维码或卡在 Sending Code。"
  elif [ "$state" = "unknown" ]; then
    printf "\n提示：未能确认系统 NTP 时间同步状态。若登录卡住，请优先检查 timedatectl status。\n"
  fi
}

login_prompt_detected() {
  local mode="$1"
  local log_file="$2"
  [ -s "$log_file" ] || return 1
  if [ "$mode" = "code" ]; then
    grep -Eiq 'Enter your phone number|phone number|\+86|发送验证码|手机号|手機號|電話號碼' "$log_file"
  else
    grep -Eiq 'QR|qr|scan|Scan|扫码|掃碼|二维码|二維碼|login token|tg://login|█|▄|▀' "$log_file"
  fi
}

run_tdl_login_plain() {
  local mode="$1"
  local args=()
  while IFS= read -r -d '' item; do args+=("$item"); done < <(tdl_base_args)
  tdl "${args[@]}" login -T "$mode"
}

run_tdl_login_via_script() {
  local mode="$1"
  local log_file="$2"
  local cmd_file="$3"
  local args=()
  while IFS= read -r -d '' item; do args+=("$item"); done < <(tdl_base_args)

  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec '
    printf '%q ' tdl "${args[@]}" login -T "$mode"
    printf '\n'
  } > "$cmd_file"
  chmod +x "$cmd_file"

  script -q -f -c "$cmd_file" "$log_file"
}

run_tdl_login_with_guard() {
  local mode="$1"
  local log_file="$TMP_ROOT/login-${mode}.log"
  local cmd_file="$TMP_ROOT/login-${mode}.sh"
  local timeout_file="$TMP_ROOT/login-${mode}.timeout"
  rm -f "$log_file" "$cmd_file" "$timeout_file"
  mkdir -p "$TMP_ROOT"

  if ! command -v script >/dev/null 2>&1; then
    printf "提示：当前系统没有 script 命令，无法检测二维码/手机号提示是否返回，将直接运行 tdl 登录。\n"
    run_tdl_login_plain "$mode"
    return $?
  fi

  printf "登录保护：如果 %s 秒内没有检测到二维码/扫码提示或手机号输入提示，脚本会中止登录并提示检查 NTP 时间同步。\n" "$LOGIN_PROMPT_TIMEOUT"

  run_tdl_login_via_script "$mode" "$log_file" "$cmd_file" &
  local login_pid=$!

  (
    local waited=0
    while kill -0 "$login_pid" >/dev/null 2>&1; do
      if login_prompt_detected "$mode" "$log_file"; then
        exit 0
      fi
      if [ "$waited" -ge "$LOGIN_PROMPT_TIMEOUT" ]; then
        printf "prompt-timeout" > "$timeout_file"
        pkill -TERM -P "$login_pid" >/dev/null 2>&1 || true
        kill "$login_pid" >/dev/null 2>&1 || true
        sleep 1
        pkill -KILL -P "$login_pid" >/dev/null 2>&1 || true
        kill -9 "$login_pid" >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
  ) &
  local guard_pid=$!

  wait "$login_pid"
  local status=$?
  kill "$guard_pid" >/dev/null 2>&1 || true
  wait "$guard_pid" >/dev/null 2>&1 || true

  if [ -f "$timeout_file" ]; then
    return 124
  fi
  return "$status"
}

ensure_runtime_dependencies() {
  local missing=""
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v awk >/dev/null 2>&1 || missing="$missing awk"
  command -v sed >/dev/null 2>&1 || missing="$missing sed"
  command -v date >/dev/null 2>&1 || missing="$missing coreutils"
  if [ -z "$missing" ]; then
    return 0
  fi
  printf "%s缺少基础命令：%s%s\n" "$C_YELLOW" "$missing" "$C_RESET"
  printf "将尝试使用当前系统的软件包管理器安装。\n"
  install_packages_if_possible $missing || {
    printf "%s无法自动安装依赖。请手动安装 curl、awk、sed、date/coreutils 后重试。%s\n" "$C_RED" "$C_RESET" >&2
    return 1
  }
}

maybe_install_shortcut() {
  if command -v "$SHORTCUT_NAME" >/dev/null 2>&1; then
    return 0
  fi
  printf "正在安装联网快捷命令：%s\n" "$SHORTCUT_NAME"
  if install_shortcut "$SHORTCUT_PATH"; then
    printf "已安装：%s\n" "$SHORTCUT_PATH"
    printf "后续可直接运行：%s\n\n" "$SHORTCUT_NAME"
  else
    cat <<EOF
未能自动写入 ${SHORTCUT_PATH}。
你可以稍后用 root 运行：
  bash <(curl -fsSL ${RAW_URL}) setup

EOF
  fi
}

setup_shortcut_only() {
  print_origin
  if install_shortcut "$SHORTCUT_PATH"; then
    printf "\n已安装联网快捷命令：%s\n" "$SHORTCUT_PATH"
    printf "以后运行：%s\n" "$SHORTCUT_NAME"
    printf "每次都会从 GitHub 拉取最新版脚本执行，不使用本地缓存脚本。\n"
  else
    printf "\n安装失败：需要 root 或 sudo 权限写入 %s\n" "$SHORTCUT_PATH" >&2
    exit 1
  fi
}

install_tdl_if_needed() {
  ensure_runtime_dependencies || return 1

  if command -v tdl >/dev/null 2>&1; then
    return 0
  fi

  printf "未检测到 tdl，将临时安装 iyear/tdl。\n"
  printf "退出脚本时默认会删除本次临时安装的 tdl 主程序。\n\n"

  if [ "$(id -u)" = "0" ]; then
    curl -fsSL "$TDL_INSTALL_URL" | bash
  elif command -v sudo >/dev/null 2>&1; then
    curl -fsSL "$TDL_INSTALL_URL" | sudo bash
  else
    printf "当前用户不是 root，且没有 sudo，无法自动安装 tdl。\n" >&2
    return 1
  fi

  if command -v tdl >/dev/null 2>&1; then
    TDL_INSTALLED_BY_THIS_RUN=1
    TDL_INSTALLED_PATH="$(command -v tdl)"
    return 0
  fi

  printf "tdl 安装后仍不可用，请检查 PATH。\n" >&2
  return 1
}

tdl_base_args() {
  printf "%s\0" "-n" "$NAMESPACE"
  printf "%s\0" "--storage" "type=bolt,path=${SESSION_DIR}/data"
  printf "%s\0" "--disable-progress-ps"
  if [ -n "$PROXY" ]; then
    printf "%s\0" "--proxy" "$PROXY"
  fi
}

run_tdl_login() {
  local mode="$1"
  install_tdl_if_needed || return 1
  ensure_dirs
  pre_login_time_check
  printf "\n登录方式：%s\n" "$mode"
  printf "登录数据目录：%s\n\n" "$SESSION_DIR"

  run_tdl_login_with_guard "$mode"
  local status=$?
  if [ "$status" = "124" ]; then
    prompt_time_sync_repair "tdl 登录在 ${LOGIN_PROMPT_TIMEOUT} 秒内没有返回二维码/扫码提示或手机号输入提示，已自动中止。常见原因是 VPS 时间未同步导致 Telegram 认证请求无响应。"
    return 1
  elif [ "$status" != "0" ]; then
    prompt_time_sync_repair "tdl 登录返回失败状态 $status。若你看到二维码/验证码没有返回，优先检查并修复 NTP 时间同步。"
    return "$status"
  fi
}

set_video_url() {
  printf "\n粘贴 Telegram 频道/群组中具体资源消息链接（建议使用较大的视频或文件）：\n> "
  read -r TG_URL || TG_URL=""
  save_config
}

set_proxy_menu() {
  clear_screen
  print_origin
  cat <<EOF

当前连接方式：$(redact_proxy "$PROXY")

1. VPS 直连 Telegram
2. SOCKS5：127.0.0.1:1080
3. SOCKS5：127.0.0.1:10808
4. SOCKS5：127.0.0.1:7891
5. HTTP：127.0.0.1:7890
6. 自定义代理地址
0. 返回
EOF
  printf "\n请选择："
  read -r choice || choice=""
  case "$choice" in
    1) PROXY="" ;;
    2) PROXY="socks5://127.0.0.1:1080" ;;
    3) PROXY="socks5://127.0.0.1:10808" ;;
    4) PROXY="socks5://127.0.0.1:7891" ;;
    5) PROXY="http://127.0.0.1:7890" ;;
    6)
      printf "输入代理，例如 socks5://user:pass@127.0.0.1:1080\n> "
      read -r PROXY || PROXY=""
      ;;
    0) return ;;
    *) printf "无效选择。\n"; pause; return ;;
  esac
  save_config
}

login_menu() {
  clear_screen
  print_origin
  cat <<EOF

Telegram 登录管理

当前代理：$(redact_proxy "$PROXY")
登录数据：$SESSION_DIR

1. 二维码登录
2. 手机号验证码登录
3. 检查/修复 NTP 时间同步
4. 删除本脚本的 Telegram 登录数据
0. 返回
EOF
  printf "\n请选择："
  read -r choice || choice=""
  case "$choice" in
    1) run_tdl_login "qr"; pause ;;
    2) run_tdl_login "code"; pause ;;
    3) prompt_time_sync_repair "手动检查 Telegram 登录相关的 NTP 时间同步。用于修复二维码不返回、手机号提示不出现、或卡在 Sending Code 的问题。"; pause ;;
    4) rm -rf "$SESSION_DIR"; mkdir -p "$SESSION_DIR"; printf "已删除登录数据。\n"; pause ;;
    0) return ;;
    *) printf "无效选择。\n"; pause ;;
  esac
}

profile_menu() {
  clear_screen
  print_origin
  cat <<EOF

选择测速强度

1. 极低资源：12秒，多连接2线程，64MiB上限
2. 推荐低资源：20秒，多连接4线程，128MiB上限
3. 标准测试：30秒，多连接8线程，256MiB上限
4. 自定义
0. 返回
EOF
  printf "\n请选择："
  read -r choice || choice=""
  case "$choice" in
    1) PROFILE_NAME="极低资源"; TEST_SECONDS=12; MULTI_THREADS=2; MULTI_POOL=2; LIMIT_MIB=64 ;;
    2) PROFILE_NAME="推荐低资源"; TEST_SECONDS=20; MULTI_THREADS=4; MULTI_POOL=4; LIMIT_MIB=128 ;;
    3) PROFILE_NAME="标准测试"; TEST_SECONDS=30; MULTI_THREADS=8; MULTI_POOL=8; LIMIT_MIB=256 ;;
    4) custom_profile ;;
    0) return ;;
    *) printf "无效选择。\n"; pause; return ;;
  esac
  save_config
  start_benchmark
}

choose_from() {
  local prompt="$1"; shift
  local default="$1"; shift
  local values=("$@")
  local i choice
  printf "\n%s\n" "$prompt"
  for i in "${!values[@]}"; do
    printf "%d. %s\n" "$((i + 1))" "${values[$i]}"
  done
  printf "请选择，默认 %s： " "$default"
  read -r choice || choice=""
  if [ -z "$choice" ]; then
    printf "%s" "$default"
    return
  fi
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#values[@]}" ]; then
    printf "%s" "${values[$((choice - 1))]}"
  else
    printf "%s" "$default"
  fi
}

custom_profile() {
  PROFILE_NAME="自定义"
  TEST_SECONDS="$(choose_from "每轮测速时长（秒）" "20" 10 20 30 60)"
  MULTI_THREADS="$(choose_from "多连接线程数" "4" 2 4 8 12)"
  MULTI_POOL="$MULTI_THREADS"
  LIMIT_MIB="$(choose_from "每轮最大下载占用（MiB）" "128" 64 128 256 512)"
}

confirm_ready() {
  if [ -z "$TG_URL" ]; then
    set_video_url
  fi
  [ -n "$TG_URL" ] || return 1
  clear_screen
  print_origin
  cat <<EOF

即将开始测速

资源链接：$TG_URL
连接方式：$(redact_proxy "$PROXY")
方案：$PROFILE_NAME
单连接：1线程 / 1连接池 / ${TEST_SECONDS}秒
多连接：${MULTI_THREADS}线程 / ${MULTI_POOL}连接池 / ${TEST_SECONDS}秒
每轮磁盘上限：${LIMIT_MIB}MiB

1. 开始
0. 取消
EOF
  printf "\n请选择："
  read -r choice || choice=""
  [ "$choice" = "1" ]
}

run_one_test() {
  local label="$1"
  local threads="$2"
  local pool="$3"
  local seconds="$4"
  local limit_mib="$5"
  local run_dir="$TMP_ROOT/$label"
  local log_file="$TMP_ROOT/${label}.log"
  local limit_bytes=$((limit_mib * 1024 * 1024))
  local start end elapsed size status

  rm -rf "$run_dir"
  mkdir -p "$run_dir"

  local args=()
  while IFS= read -r -d '' item; do args+=("$item"); done < <(tdl_base_args)

  start="$(date +%s)"
  tdl "${args[@]}" --pool "$pool" dl \
    -u "$TG_URL" \
    -d "$run_dir" \
    -t "$threads" \
    -l 1 \
    --restart \
    >"$log_file" 2>&1 &
  CURRENT_TDL_PID=$!

  while kill -0 "$CURRENT_TDL_PID" >/dev/null 2>&1; do
    sleep 1
    size="$(dir_size_bytes "$run_dir")"
    end="$(date +%s)"
    elapsed=$((end - start))
    draw_progress "$label" "$elapsed" "$seconds" "$size" "$limit_bytes"
    if [ "$size" -ge "$limit_bytes" ] || [ "$elapsed" -ge "$seconds" ]; then
      kill "$CURRENT_TDL_PID" >/dev/null 2>&1 || true
      break
    fi
  done

  wait "$CURRENT_TDL_PID" >/dev/null 2>&1 || true
  CURRENT_TDL_PID=""
  printf "\n" >&2

  end="$(date +%s)"
  elapsed=$((end - start))
  [ "$elapsed" -lt 1 ] && elapsed=1
  size="$(dir_size_bytes "$run_dir")"
  status="$(tail -n 12 "$log_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
  rm -rf "$run_dir" "$log_file" >/dev/null 2>&1 || true

  awk -v b="$size" -v s="$elapsed" 'BEGIN {
    mibs=b/s/1048576;
    mbps=b*8/s/1000000;
    printf "%.2f %.2f", mibs, mbps
  }'

  if [ "$size" -lt 1048576 ]; then
    printf " WARN:%s" "$status"
  fi
}

start_benchmark() {
  install_tdl_if_needed || { pause; return; }
  confirm_ready || return
  ensure_dirs
  rm -rf "$TMP_ROOT"
  mkdir -p "$TMP_ROOT"

  printf "\n开始单连接敏感性测试...\n"
  local single
  single="$(run_one_test "single" 1 1 "$TEST_SECONDS" "$LIMIT_MIB")"
  LAST_SINGLE_MIBS="$(printf "%s" "$single" | awk '{print $1}')"
  LAST_SINGLE_MBPS="$(printf "%s" "$single" | awk '{print $2}')"

  printf "\n开始多连接总吞吐测试...\n"
  local multi
  multi="$(run_one_test "multi" "$MULTI_THREADS" "$MULTI_POOL" "$TEST_SECONDS" "$LIMIT_MIB")"
  LAST_MULTI_MIBS="$(printf "%s" "$multi" | awk '{print $1}')"
  LAST_MULTI_MBPS="$(printf "%s" "$multi" | awk '{print $2}')"

  show_result
  pause
}

show_result() {
  clear_screen
  print_origin
  cat <<EOF

测速结果

单连接敏感性：${LAST_SINGLE_MIBS:---} MiB/s    ${LAST_SINGLE_MBPS:---} Mbps
多连接总吞吐：${LAST_MULTI_MIBS:---} MiB/s    ${LAST_MULTI_MBPS:---} Mbps

EOF
  if [ -n "$LAST_SINGLE_MBPS" ] && [ -n "$LAST_MULTI_MBPS" ]; then
    awk -v s="$LAST_SINGLE_MBPS" -v m="$LAST_MULTI_MBPS" 'BEGIN {
      if (s < 1 && m < 1) {
        print "判断：几乎没有有效下载，优先检查登录、链接权限、代理或 Telegram 连通性。"
      } else if (s < 10 && m >= 50) {
        print "判断：总吞吐能跑起来，但单连接弱，容易表现为视频首开慢、拖动后缓冲久。"
      } else if (s < 10 && m < 20) {
        print "判断：VPS 到 Telegram 文件方向整体偏弱，普通 Speedtest 快也不能排除此问题。"
      } else if (m > s * 2.5) {
        print "判断：线路明显依赖并发，实际 Telegram 客户端体验可能低于多连接结果。"
      } else {
        print "判断：VPS 到 Telegram 的文件下载方向没有明显单连接瓶颈。"
      }
    }'
  fi
}

result_menu() {
  clear
  show_result
  cat <<EOF

1. 导出到 $RESULT_FILE
0. 返回
EOF
  printf "\n请选择："
  read -r choice || choice=""
  case "$choice" in
    1)
      {
        print_origin
        printf "\n资源链接：%s\n连接方式：%s\n方案：%s\n" "$TG_URL" "$(redact_proxy "$PROXY")" "$PROFILE_NAME"
        printf "单连接敏感性：%s MiB/s    %s Mbps\n" "${LAST_SINGLE_MIBS:---}" "${LAST_SINGLE_MBPS:---}"
        printf "多连接总吞吐：%s MiB/s    %s Mbps\n" "${LAST_MULTI_MIBS:---}" "${LAST_MULTI_MBPS:---}"
      } > "$RESULT_FILE"
      printf "已导出。\n"
      pause
      ;;
  esac
}

clean_menu() {
  clear_screen
  print_origin
  cat <<EOF

清理与空间设置

1. 立即清理临时视频、残片和日志
2. 删除已导出的轻量结果文件
3. 删除本脚本的 Telegram 登录数据
4. 切换退出时是否保留本次临时安装的 tdl（当前：$([ "$KEEP_TDL" = "1" ] && printf "保留" || printf "退出删除")）
0. 返回
EOF
  printf "\n请选择："
  read -r choice || choice=""
  case "$choice" in
    1) rm -rf "$TMP_ROOT"; mkdir -p "$TMP_ROOT"; printf "已清理临时目录。\n"; pause ;;
    2) rm -f "$RESULT_FILE"; printf "已删除结果文件。\n"; pause ;;
    3) rm -rf "$SESSION_DIR"; mkdir -p "$SESSION_DIR"; printf "已删除登录数据。\n"; pause ;;
    4)
      if [ "$KEEP_TDL" = "1" ]; then KEEP_TDL=0; else KEEP_TDL=1; fi
      KEEP_TDL_USER_SET=1
      save_config
      printf "当前设置：退出时%s删除本次临时安装的 tdl。\n" "$([ "$KEEP_TDL" = "1" ] && printf "不" || printf "会")"
      pause
      ;;
  esac
}

main_menu() {
  maybe_install_shortcut
  while true; do
    clear_screen
    print_origin
    rule
    status_line "资源" "${TG_URL:-未设置}"
    status_line "连接" "$(redact_proxy "$PROXY")"
    status_line "方案" "$PROFILE_NAME"
    status_line "结果" "单 ${LAST_SINGLE_MBPS:---} Mbps / 多 ${LAST_MULTI_MBPS:---} Mbps"
    rule
    menu_item 1 "一键开始推荐低资源测速"
    menu_item 2 "选择测速强度并开始"
    menu_item 3 "设置/更换 Telegram 资源消息链接"
    menu_item 4 "设置直连或代理"
    menu_item 5 "Telegram 登录管理"
    menu_item 6 "查看或导出本次结果"
    menu_item 7 "清理与空间设置"
    menu_item 0 "自动清理并退出"
    printf "\n请选择："
    read -r choice || choice=""
    case "$choice" in
      1) PROFILE_NAME="推荐低资源"; TEST_SECONDS=20; MULTI_THREADS=4; MULTI_POOL=4; LIMIT_MIB=128; save_config; start_benchmark ;;
      2) profile_menu ;;
      3) set_video_url ;;
      4) set_proxy_menu ;;
      5) login_menu ;;
      6) result_menu ;;
      7) clean_menu ;;
      0) save_config; printf "正在清理并退出...\n"; exit 0 ;;
      *) printf "无效选择。\n"; pause ;;
    esac
  done
}

usage() {
  print_origin
  cat <<EOF

用法：
  bash <(curl -fsSL ${RAW_URL})
  bash <(curl -fsSL ${RAW_URL}) setup
  tst

首次运行会尝试安装联网快捷命令 tst。
tst 每次运行都会从 GitHub 拉取最新版脚本执行，不使用本地缓存脚本。
EOF
}

ensure_dirs
load_config

case "${1:-}" in
  setup|setup-shortcut|install) setup_shortcut_only ;;
  --version|-v|version) print_origin ;;
  --help|-h|help) usage ;;
  *) main_menu ;;
esac
