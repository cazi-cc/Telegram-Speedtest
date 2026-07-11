#!/usr/bin/env bash
set -u

APP_NAME="telegram-speedtest"
APP_VERSION="0.4.0"
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

TG_URL=""
PROXY=""
PROFILE_NAME="推荐低资源"
TEST_SECONDS=20
MULTI_THREADS=4
MULTI_POOL=4
LIMIT_MIB=128
KEEP_TDL=0
LAST_SINGLE_MIBS=""
LAST_SINGLE_MBPS=""
LAST_MULTI_MIBS=""
LAST_MULTI_MBPS=""
CURRENT_TDL_PID=""
TDL_INSTALLED_BY_THIS_RUN=0
TDL_INSTALLED_PATH=""

print_origin() {
  cat <<EOF
${APP_NAME} ${APP_VERSION}
出处：${REPO_URL}
说明：本脚本是 iyear/tdl 的独立交互式封装，不是 Telegram 或 tdl 官方项目。
EOF
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
    install -m 755 "$tmp" "$target"
    rm -f "$tmp"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo install -m 755 "$tmp" "$target"
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
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
  if command -v tdl >/dev/null 2>&1; then
    return 0
  fi

  printf "未检测到 tdl，将临时安装 iyear/tdl。\n"
  printf "退出脚本时默认会删除本次临时安装的 tdl 主程序。\n\n"

  if ! command -v curl >/dev/null 2>&1; then
    printf "缺少 curl，Debian/Ubuntu 可先安装：apt update && apt install -y curl\n" >&2
    return 1
  fi

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
  printf "\n登录方式：%s\n" "$mode"
  printf "登录数据目录：%s\n\n" "$SESSION_DIR"

  local args=()
  while IFS= read -r -d '' item; do args+=("$item"); done < <(tdl_base_args)
  tdl "${args[@]}" login -T "$mode"
}

set_video_url() {
  printf "\n粘贴 Telegram 频道/群组中具体视频消息链接：\n> "
  read -r TG_URL || TG_URL=""
  save_config
}

set_proxy_menu() {
  clear
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
  clear
  print_origin
  cat <<EOF

Telegram 登录管理

当前代理：$(redact_proxy "$PROXY")
登录数据：$SESSION_DIR

1. 二维码登录
2. 手机号验证码登录
3. 删除本脚本的 Telegram 登录数据
0. 返回
EOF
  printf "\n请选择："
  read -r choice || choice=""
  case "$choice" in
    1) run_tdl_login "qr"; pause ;;
    2) run_tdl_login "code"; pause ;;
    3) rm -rf "$SESSION_DIR"; mkdir -p "$SESSION_DIR"; printf "已删除登录数据。\n"; pause ;;
    0) return ;;
    *) printf "无效选择。\n"; pause ;;
  esac
}

profile_menu() {
  clear
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
  clear
  print_origin
  cat <<EOF

即将开始测速

视频链接：$TG_URL
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
    printf "\r%-12s 已下载 %s / 上限 %s，已运行 %ss / %ss" \
      "$label" "$(human_size "$size")" "$(human_size "$limit_bytes")" "$elapsed" "$seconds" >&2
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
  clear
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
        printf "\n视频链接：%s\n连接方式：%s\n方案：%s\n" "$TG_URL" "$(redact_proxy "$PROXY")" "$PROFILE_NAME"
        printf "单连接敏感性：%s MiB/s    %s Mbps\n" "${LAST_SINGLE_MIBS:---}" "${LAST_SINGLE_MBPS:---}"
        printf "多连接总吞吐：%s MiB/s    %s Mbps\n" "${LAST_MULTI_MIBS:---}" "${LAST_MULTI_MBPS:---}"
      } > "$RESULT_FILE"
      printf "已导出。\n"
      pause
      ;;
  esac
}

status_menu() {
  clear
  print_origin
  local tmp_size session_size config_size tdl_path
  tmp_size="$(dir_size_bytes "$TMP_ROOT")"
  session_size="$(dir_size_bytes "$SESSION_DIR")"
  config_size="$(dir_size_bytes "$CONFIG_DIR")"
  tdl_path="$(command -v tdl 2>/dev/null || true)"
  cat <<EOF

资源与状态

内存：
$(free -h 2>/dev/null || printf "当前系统没有 free 命令\n")

磁盘：
$(df -h "$HOME" "${TMPDIR:-/tmp}" 2>/dev/null || true)

脚本临时目录：$TMP_ROOT ($(human_size "$tmp_size"))
配置目录：$CONFIG_DIR ($(human_size "$config_size"))
Telegram 登录数据：$SESSION_DIR ($(human_size "$session_size"))
tdl：${tdl_path:-未安装}
退出时删除本次临时安装的 tdl：$([ "$KEEP_TDL" = "1" ] && printf "否" || printf "是")

视频链接：${TG_URL:-未设置}
连接方式：$(redact_proxy "$PROXY")
测试方案：$PROFILE_NAME
EOF
  pause
}

clean_menu() {
  clear
  print_origin
  cat <<EOF

清理与空间设置

1. 立即清理临时视频、残片和日志
2. 删除已导出的轻量结果文件
3. 删除本脚本的 Telegram 登录数据
4. 切换退出时是否保留本次临时安装的 tdl
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
      save_config
      printf "当前设置：退出时%s删除本次临时安装的 tdl。\n" "$([ "$KEEP_TDL" = "1" ] && printf "不" || printf "会")"
      pause
      ;;
  esac
}

main_menu() {
  maybe_install_shortcut
  while true; do
    clear
    print_origin
    cat <<EOF

低 RAM / 低硬盘交互版，基于 iyear/tdl
--------------------------------------------------
当前链接：${TG_URL:-未设置}
连接方式：$(redact_proxy "$PROXY")
测试方案：$PROFILE_NAME
最后结果：单 ${LAST_SINGLE_MBPS:---} Mbps / 多 ${LAST_MULTI_MBPS:---} Mbps
--------------------------------------------------

1. 一键开始推荐低资源测速
2. 选择测速强度并开始
3. 设置/更换频道视频消息链接
4. 设置直连或代理
5. Telegram 登录管理
6. 查看或导出本次结果
7. 查看 RAM、硬盘和占用状态
8. 清理与空间设置
0. 自动清理并退出
EOF
    printf "\n请选择："
    read -r choice || choice=""
    case "$choice" in
      1) PROFILE_NAME="推荐低资源"; TEST_SECONDS=20; MULTI_THREADS=4; MULTI_POOL=4; LIMIT_MIB=128; save_config; start_benchmark ;;
      2) profile_menu ;;
      3) set_video_url ;;
      4) set_proxy_menu ;;
      5) login_menu ;;
      6) result_menu ;;
      7) status_menu ;;
      8) clean_menu ;;
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
