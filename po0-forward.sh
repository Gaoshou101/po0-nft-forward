#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# po0-forward.sh — Po0（腾讯云 CCN）入口机 nftables 端口转发管理脚本
#
# 适用场景：客户端 → Po0 入口机（公网 IP）══腾讯云 CCN 内网══ 境外出口机
#
# 本脚本在通用 nftables 转发脚本基础上，针对 Po0 链路做了 5 处加固：
#   1) SNAT 源地址默认从【本机私网地址】中选取，避免误填公网 IP
#      （Po0 要求 SNAT 成内网 IP，否则回包不走 CCN 内网链路）
#   2) 内置 MSS 钳制（maxseg 1452），避免 CCN 链路 MTU 不匹配导致大流量断流
#   3) Po0 双向封禁端口（80/443/8080/8443/8000/1080）输入时强制二次确认
#   4) sysctl 按 key 合并写入，不再整体覆盖文件（避免冲掉你手写的内核参数）
#   5) 单条规则失败不再中断整个脚本，可继续添加下一条
#
# Po0 链路两个关键参数（最容易搞反，详见 README）：
#   * 目标 IP  = 出口机 / 落地机的【公网 IP】（CCN 内部送达，不要填内网 IP）
#   * SNAT 源  = 本机（Po0 入口机）的【内网 IP】（回包才会走 CCN 内网）
#
# 所有配置项均可用同名环境变量覆盖。
# ============================================================================

NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
NFT_STATE_CONF="${NFT_STATE_CONF:-/etc/nftables.d/port-forward.nft}"
MSS_CONF="${MSS_CONF:-/etc/nftables.d/mss-clamp.nft}"
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.d/99-po0-forward.conf}"
TABLE_FAMILY="${TABLE_FAMILY:-ip}"
# 使用独立表，避免清理规则时影响系统或 Docker 的 ip/nat 表。
TABLE_NAME="${TABLE_NAME:-port_forward}"
MSS_TABLE="${MSS_TABLE:-po0_mss}"
CHAIN_PRE="${CHAIN_PRE:-prerouting}"
CHAIN_POST="${CHAIN_POST:-postrouting}"
MSS_SIZE="${MSS_SIZE:-1452}"
CONNTRACK_MAX="${CONNTRACK_MAX:-32768}"
COMMENT_TAG="${COMMENT_TAG:-managed-by-po0-forward}"

# Po0 国内入口（广州 BGP / 华东 BGP）默认双向封禁的 TCP/UDP 端口
BANNED_PORTS=(80 443 8080 8443 8000 1080)

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行。"
}

need_command() {
  local command_name="$1" package_name="$2"
  command -v "$command_name" >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || die "缺少 $command_name，且未找到 apt-get。"
  info "正在安装 $package_name ..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name"
}

# 读取一行；stdin 已关闭（EOF）时直接退出，避免脚本陷入死循环
prompt_read() {
  local msg="$1" outvar="$2"
  if ! read -r -p "$msg" "$outvar"; then
    printf '\n检测到输入结束（stdin 已关闭），退出。\n' >&2
    exit 1
  fi
}

prompt_default() {
  local msg="$1" def="$2" value
  prompt_read "$msg [$def]: " value
  value="${value//[[:space:]]/}"
  printf '%s\n' "${value:-$def}"
}

prompt_required() {
  local msg="$1" value
  while true; do
    prompt_read "$msg: " value
    value="${value//[[:space:]]/}"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return
    fi
    printf '不能为空，请重新输入。\n' >&2
  done
}

confirm() {
  local answer
  answer="$(prompt_default "$1 (y/n)" "n")"
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

valid_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && ((10#$value >= 1 && 10#$value <= 65535))
}

valid_ipv4() {
  local value="$1" part
  local -a octets
  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  ((${#octets[@]} == 4)) || return 1
  for part in "${octets[@]}"; do
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
}

prompt_port() {
  local msg="$1" def="${2:-}" value
  while true; do
    if [[ -n "$def" ]]; then
      value="$(prompt_default "$msg" "$def")"
    else
      value="$(prompt_required "$msg")"
    fi
    if valid_port "$value"; then
      printf '%s\n' "$((10#$value))"
      return
    fi
    printf '端口必须是 1-65535 之间的整数。\n' >&2
  done
}

prompt_ipv4() {
  local msg="$1" def="${2:-}" value
  while true; do
    if [[ -n "$def" ]]; then
      value="$(prompt_default "$msg" "$def")"
    else
      value="$(prompt_required "$msg")"
    fi
    if valid_ipv4 "$value"; then
      printf '%s\n' "$value"
      return
    fi
    printf '请输入有效的 IPv4 地址。\n' >&2
  done
}

# ---------------------------------------------------------------------------
# 地址探测
# ---------------------------------------------------------------------------

# 列出本机所有私网 IPv4 地址（10/8、172.16/12、192.168/16）
list_private_ipv4() {
  ip -4 -o addr show 2>/dev/null | awk '
    $3=="inet" {
      split($4, a, "/"); addr=a[1];
      if (addr ~ /^10\./ || addr ~ /^192\.168\./ ||
          addr ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) print addr;
    }'
}

# 兜底：取默认路由的源地址（在 Po0 机器上通常是公网 IP，仅作提示用）
get_default_lan_ip() {
  local value
  value="$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
  printf '%s\n' "${value:-}"
}

# 选择用于 SNAT 的内网 IP —— 这是 Po0 链路最容易填错的一项
prompt_snat_ip() {
  local -a candidates=()
  local value choice i
  while IFS= read -r value; do
    [[ -n "$value" ]] && candidates+=("$value")
  done < <(list_private_ipv4)

  if ((${#candidates[@]} == 1)); then
    printf '检测到本机私网地址：%s\n' "${candidates[0]}" >&2
    prompt_ipv4 "SNAT 内网 IP" "${candidates[0]}"
    return
  fi

  if ((${#candidates[@]} > 1)); then
    printf '检测到多个本机私网地址，请选择用于 Po0 内网互通的那个：\n' >&2
    i=0
    for value in "${candidates[@]}"; do
      ((++i))
      printf '  %d) %s\n' "$i" "$value" >&2
    done
    while true; do
      choice="$(prompt_default "请输入编号" "1")"
      if [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#candidates[@]})); then
        value="${candidates[10#$choice - 1]}"
        if valid_ipv4 "$value"; then
          printf '%s\n' "$value"
          return
        fi
      fi
      printf '编号无效，请重新输入。\n' >&2
    done
  fi

  printf '\n' >&2
  warn "未检测到任何私网 IPv4 地址。"
  printf '       Po0 要求 SNAT 源地址使用【内网 IP】，不能用公网 IP。\n' >&2
  printf '       请到商家面板确认内网 IP 后手动填写（不可直接回车）。\n\n' >&2
  prompt_ipv4 "SNAT 内网 IP（必填）"
}

# ---------------------------------------------------------------------------
# 封禁端口检查
# ---------------------------------------------------------------------------

is_banned_port() {
  local p="$1" b
  for b in "${BANNED_PORTS[@]}"; do
    [[ "$p" == "$b" ]] && return 0
  done
  return 1
}

# 命中封禁端口时返回 1（调用方应跳过本条）
warn_banned_port() {
  local p="$1" role="$2"
  is_banned_port "$p" || return 0
  printf '\n' >&2
  warn "端口 $p（$role）属于 Po0 默认双向封禁端口：${BANNED_PORTS[*]}"
  printf '       使用该端口极大概率“转发不通”，并可能触发商家风控。\n' >&2
  confirm "仍要使用这个端口吗？"
}

# ---------------------------------------------------------------------------
# 系统参数与 MSS 钳制
# ---------------------------------------------------------------------------

# 按 key 合并写入 sysctl 配置：已存在同名 key 就保留用户的值，绝不整体覆盖文件
ensure_sysctl() {
  local key="$1" value="$2" pattern
  mkdir -p "$(dirname "$SYSCTL_CONF")"
  pattern="^[[:space:]]*${key//./\\.}[[:space:]]*="
  if [[ ! -f "$SYSCTL_CONF" ]]; then
    printf '%s=%s\n' "$key" "$value" >"$SYSCTL_CONF"
    return 0
  fi
  if grep -Eq "$pattern" "$SYSCTL_CONF"; then
    return 0
  fi
  printf '%s=%s\n' "$key" "$value" >>"$SYSCTL_CONF"
}

mss_content() {
  cat <<EOF
#!/usr/sbin/nft -f
# 由 po0-forward.sh 生成：MSS 钳制，避免 CCN 链路 MTU 不匹配导致大流量卡死。
table ip $MSS_TABLE {
  chain forward {
    type filter hook forward priority -150; policy accept;
    tcp flags syn tcp option maxseg size set $MSS_SIZE
  }
}
EOF
}

ensure_mss() {
  local desired tmp
  desired="$(mss_content)"
  if [[ -f "$MSS_CONF" ]] && [[ "$(<"$MSS_CONF")" == "$desired" ]] &&
    nft list table ip "$MSS_TABLE" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$(dirname "$MSS_CONF")"
  tmp="$(mktemp "${MSS_CONF}.tmp.XXXXXX")"
  printf '%s\n' "$desired" >"$tmp"
  chmod 600 "$tmp"
  nft delete table ip "$MSS_TABLE" >/dev/null 2>&1 || true
  if ! nft -f "$tmp"; then
    rm -f "$tmp"
    die "MSS 钳制规则加载失败：当前 nftables 可能不支持 tcp option maxseg（建议 >= 0.9.3）。"
  fi
  mv -f "$tmp" "$MSS_CONF"
  ok "已启用 MSS 钳制（maxseg $MSS_SIZE）"
}

# ---------------------------------------------------------------------------
# 持久化
# ---------------------------------------------------------------------------

ensure_include() {
  local line
  mkdir -p "$(dirname "$NFT_CONF")" "$(dirname "$NFT_STATE_CONF")" "$(dirname "$MSS_CONF")"
  for line in "include \"$MSS_CONF\"" "include \"$NFT_STATE_CONF\""; do
    if [[ ! -e "$NFT_CONF" ]]; then
      printf '#!/usr/sbin/nft -f\n\n%s\n' "$line" >"$NFT_CONF"
      continue
    fi
    if ! grep -Fqx "$line" "$NFT_CONF"; then
      cp -a "$NFT_CONF" "${NFT_CONF}.bak.$(date +%Y%m%d%H%M%S)"
      printf '\n# Managed by po0-forward.sh\n%s\n' "$line" >>"$NFT_CONF"
    fi
  done
}

save_rules() {
  local tmp
  mkdir -p "$(dirname "$NFT_STATE_CONF")"
  tmp="$(mktemp "${NFT_STATE_CONF}.tmp.XXXXXX")"
  {
    printf '#!/usr/sbin/nft -f\n'
    printf '# 由 po0-forward.sh 生成；脚本运行期间请勿手工编辑。\n\n'
    nft list table "$TABLE_FAMILY" "$TABLE_NAME"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$NFT_STATE_CONF"
  ensure_include
}

ensure_base() {
  need_command nft nftables
  need_command ip iproute2

  ensure_sysctl net.ipv4.ip_forward 1
  ensure_sysctl net.ipv4.tcp_mtu_probing 1
  ensure_sysctl net.netfilter.nf_conntrack_max "$CONNTRACK_MAX"
  sysctl --system >/dev/null 2>&1 || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 ||
    warn "无法立即开启 ip_forward；重启后会由 $SYSCTL_CONF 生效。"

  ensure_mss

  if ! nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
    if [[ -s "$NFT_STATE_CONF" ]]; then
      nft -f "$NFT_STATE_CONF" || die "持久化规则加载失败：$NFT_STATE_CONF"
    else
      nft add table "$TABLE_FAMILY" "$TABLE_NAME"
    fi
  fi

  if ! nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PRE" >/dev/null 2>&1; then
    nft add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PRE" \
      '{ type nat hook prerouting priority -100; policy accept; }'
  fi
  if ! nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_POST" >/dev/null 2>&1; then
    nft add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_POST" \
      '{ type nat hook postrouting priority 100; policy accept; }'
  fi

  save_rules
  systemctl enable nftables >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 规则读取
# ---------------------------------------------------------------------------

# 输出：proto,inport,destination,handle
extract_dnat_csv() {
  nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PRE" 2>/dev/null | awk '
    / dnat to / {
      proto="-"; inport="-"; dest="-"; handle="-";
      for (i=1; i<=NF; i++) {
        if (($i=="tcp" || $i=="udp") && proto=="-") proto=$i;
        if ($i=="dport") inport=$(i+1);
        if ($i=="dnat" && $(i+1)=="to") dest=$(i+2);
        if ($i=="handle") handle=$(i+1);
      }
      printf "%s,%s,%s,%s\n", proto,inport,dest,handle;
    }'
}

# 输出：proto,destination,snat_ip,handle
extract_snat_csv() {
  nft -a list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_POST" 2>/dev/null | awk '
    / snat to / {
      proto="-"; daddr="-"; dport="-"; snat="-"; handle="-";
      for (i=1; i<=NF; i++) {
        if (($i=="tcp" || $i=="udp") && proto=="-") proto=$i;
        if ($i=="daddr") daddr=$(i+1);
        if ($i=="dport") dport=$(i+1);
        if ($i=="snat" && $(i+1)=="to") snat=$(i+2);
        if ($i=="handle") handle=$(i+1);
      }
      printf "%s,%s:%s,%s,%s\n", proto,daddr,dport,snat,handle;
    }'
}

find_dnat_destination() {
  local proto="$1" inport="$2"
  extract_dnat_csv | awk -F',' -v p="$proto" -v i="$inport" '
    $1==p && $2==i {print $3; exit}'
}

# ---------------------------------------------------------------------------
# 规则增删
# ---------------------------------------------------------------------------

# 成功返回 0；失败只报错并返回 1，不终止整个脚本
add_one_rule() {
  local proto="$1" inport="$2" dip="$3" dport="$4" snatip="$5"
  local destination="$dip:$dport" item tmp existing
  local -a protocols

  [[ "$proto" == "tcp+udp" ]] && protocols=(tcp udp) || protocols=("$proto")
  for item in "${protocols[@]}"; do
    existing="$(find_dnat_destination "$item" "$inport" || true)"
    if [[ -n "$existing" ]]; then
      warn "入口端口已被占用：$item $inport 已转发到 $existing"
      return 1
    fi
  done

  tmp="$(mktemp)"
  for item in "${protocols[@]}"; do
    printf 'add rule %s %s %s %s dport %s dnat to %s comment "%s"\n' \
      "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PRE" "$item" "$inport" "$destination" "$COMMENT_TAG" >>"$tmp"
    printf 'add rule %s %s %s ip daddr %s %s dport %s snat to %s comment "%s"\n' \
      "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_POST" "$dip" "$item" "$dport" "$snatip" "$COMMENT_TAG" >>"$tmp"
  done

  if ! nft -c -f "$tmp"; then
    rm -f "$tmp"
    warn "规则校验失败，未作任何修改。"
    return 1
  fi
  if ! nft -f "$tmp"; then
    rm -f "$tmp"
    warn "规则添加失败。"
    return 1
  fi
  rm -f "$tmp"
  save_rules
}

add_rules_step_by_step() {
  local psel proto inport dip dport snatip cont

  while true; do
    printf '\n---- 新增一条转发 ----\n'
    printf '协议选项：1) tcp  2) udp  3) tcp+udp\n'
    psel="$(prompt_default "请选择协议" "1")"
    case "${psel,,}" in
      1|tcp) proto="tcp" ;;
      2|udp) proto="udp" ;;
      3|tcp+udp) proto="tcp+udp" ;;
      *) printf '无效协议，请重新选择。\n'; continue ;;
    esac

    inport="$(prompt_port "入口端口（Po0 对外监听端口）")"
    warn_banned_port "$inport" "入口端口" || { printf '已跳过该端口。\n'; continue; }

    dip="$(prompt_ipv4 "目标 IP（出口机 / 落地机的公网 IP）")"
    dport="$(prompt_port "目标端口（出口机协议监听端口）" "$inport")"
    warn_banned_port "$dport" "目标端口" || { printf '已跳过该端口。\n'; continue; }

    snatip="$(prompt_snat_ip)"

    if add_one_rule "$proto" "$inport" "$dip" "$dport" "$snatip"; then
      ok "已添加并持久化。"
    else
      printf '本条转发未添加，可重新输入。\n' >&2
    fi

    cont="$(prompt_default "是否继续添加下一条？(y/n)" "y")"
    [[ "${cont,,}" == "y" || "${cont,,}" == "yes" ]] || break
  done
}

show_merged() {
  declare -A snat_to_by_key=() snat_handle_by_key=()
  local proto dest snat handle key lines inport pre_handle post_handle no=0

  while IFS=',' read -r proto dest snat handle; do
    [[ -z "${proto:-}" ]] && continue
    key="${proto}|${dest}"
    snat_to_by_key["$key"]="$snat"
    snat_handle_by_key["$key"]="$handle"
  done < <(extract_snat_csv)

  lines="$(extract_dnat_csv || true)"
  printf '\n================ 当前端口转发表 ================\n'
  printf '%-4s %-7s %-8s %-22s %-18s %-20s\n' \
    'NO' 'PROTO' 'INPORT' 'DEST' 'SNAT_TO' 'HANDLES'
  printf '%s\n' '----------------------------------------------------------------------------------------'

  if [[ -z "$lines" ]]; then
    printf '(暂无转发规则)\n'
    return
  fi

  while IFS=',' read -r proto inport dest pre_handle; do
    [[ -z "${proto:-}" ]] && continue
    ((++no))
    key="${proto}|${dest}"
    snat="${snat_to_by_key[$key]:--}"
    post_handle="${snat_handle_by_key[$key]:--}"
    printf '%-4s %-7s %-8s %-22s %-18s pre:%-4s post:%s\n' \
      "$no" "$proto" "$inport" "$dest" "$snat" "$pre_handle" "$post_handle"
  done <<<"$lines"
}

delete_by_no() {
  local lines no target proto inport dest pre_handle snat_handle
  lines="$(extract_dnat_csv || true)"
  [[ -n "$lines" ]] || { printf '没有可删除的规则。\n'; return; }

  show_merged
  printf '\n'
  no="$(prompt_required "输入要删除的 NO")"
  [[ "$no" =~ ^[1-9][0-9]*$ ]] || { printf 'NO 必须是正整数。\n'; return; }
  target="$(sed -n "${no}p" <<<"$lines")"
  [[ -n "$target" ]] || { printf 'NO 不存在。\n'; return; }

  IFS=',' read -r proto inport dest pre_handle <<<"$target"
  printf '将删除：%s %s -> %s\n' "$proto" "$inport" "$dest"
  confirm "确定删除这条转发？" || { printf '已取消。\n'; return; }

  snat_handle="$(extract_snat_csv | awk -F',' -v p="$proto" -v d="$dest" \
    '$1==p && $2==d {print $4; exit}')"
  nft delete rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PRE" handle "$pre_handle"
  if [[ -n "$snat_handle" && "$snat_handle" != "-" ]]; then
    nft delete rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_POST" handle "$snat_handle"
  fi
  save_rules
  ok "删除完成并已持久化。"
}

clear_rules() {
  show_merged
  printf '\n该操作只清空 %s/%s 两条转发链，不删除整个表。\n' "$CHAIN_PRE" "$CHAIN_POST"
  confirm "确定清空所有转发规则？" || { printf '已取消。\n'; return; }
  nft flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PRE"
  nft flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_POST"
  save_rules
  ok "转发规则已清空并持久化。"
}

# ---------------------------------------------------------------------------
# 状态与自检
# ---------------------------------------------------------------------------

# 检测是否存在 policy drop 的 forward 链（ufw/firewalld/docker 常见），会拦掉转发
check_forward_policy() {
  if nft list ruleset 2>/dev/null | awk '
      /hook forward/ { f=1 }
      f && /policy drop/ { found=1; exit }
      f && /^[[:space:]]*}/ { f=0 }
      END { exit !found }'; then
    warn "检测到其他表的 forward 链为 policy drop（常见于 ufw / firewalld / docker）。"
    warn "这会拦截转发流量，请先放行转发或关闭这些防火墙。"
    return 1
  fi
  return 0
}

show_status() {
  local -a privates=()
  local value

  printf 'IPv4 转发: '
  sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '未知\n'

  printf '本机私网地址: '
  while IFS= read -r value; do
    [[ -n "$value" ]] && privates+=("$value")
  done < <(list_private_ipv4)
  if ((${#privates[@]} == 0)); then
    printf '(无) —— Po0 链路需要内网 IP，请到商家面板确认\n'
  else
    printf '%s\n' "${privates[*]}"
  fi

  printf 'nftables 服务: '
  systemctl is-enabled nftables 2>/dev/null || true

  printf 'MSS 钳制: '
  if nft list table ip "$MSS_TABLE" >/dev/null 2>&1; then
    printf '已启用（maxseg %s，表 ip %s）\n' "$MSS_SIZE" "$MSS_TABLE"
  else
    printf '未启用\n'
  fi

  printf '持久化文件: %s\n' "$NFT_STATE_CONF"
  printf 'MSS 文件:   %s\n' "$MSS_CONF"

  check_forward_policy || true
  show_merged
}

usage() {
  cat <<EOF
用法: $0 [menu|add|show|del|clear|status|help]

  menu    打开交互式菜单（默认）
  add     添加端口转发
  show    查看端口转发
  del     按编号删除端口转发
  clear   清空脚本使用的两条转发链
  status  显示运行状态、MSS 状态、私网地址与规则
  help    显示本帮助

可覆盖的环境变量：
  NFT_CONF($NFT_CONF)
  NFT_STATE_CONF($NFT_STATE_CONF)
  MSS_CONF($MSS_CONF)
  SYSCTL_CONF($SYSCTL_CONF)
  MSS_SIZE($MSS_SIZE)  CONNTRACK_MAX($CONNTRACK_MAX)

Po0 使用要点：
  * 目标 IP 填出口机 / 落地机的【公网 IP】；SNAT 源地址填本机的【内网 IP】。
  * 封禁端口 ${BANNED_PORTS[*]} 不可用；禁止用于回国访问。
EOF
}

menu() {
  local choice
  while true; do
    printf '\n========= Po0 端口转发管理 =========\n'
    printf '1) 添加转发\n2) 查看转发\n3) 删除规则\n4) 清空转发规则\n5) 查看状态\n0) 退出\n'
    read -r -p "请选择: " choice || exit 0
    case "$choice" in
      1) add_rules_step_by_step ;;
      2) show_merged ;;
      3) delete_by_no ;;
      4) clear_rules ;;
      5) show_status ;;
      0) exit 0 ;;
      *) printf '无效选项。\n' ;;
    esac
  done
}

main() {
  ((BASH_VERSINFO[0] >= 4)) || die "需要 Bash 4.0 或更高版本。"
  case "${1:-menu}" in
    help|-h|--help) usage; return ;;
    menu|add|show|del|clear|status) ;;
    *) usage >&2; exit 2 ;;
  esac

  need_root
  ensure_base
  case "${1:-menu}" in
    menu) menu ;;
    add) add_rules_step_by_step ;;
    show) show_merged ;;
    del) delete_by_no ;;
    clear) clear_rules ;;
    status) show_status ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
