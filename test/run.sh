#!/usr/bin/env bash
# 离线测试：mock 掉 nft / ip / sysctl / systemctl，不触碰真实内核。
T=/opt/data/po0-forward
W=$T/wd
export PATH="$T/test/bin:$PATH"
export MOCK_NFT_STATE="$W/state.json"
export MOCK_NFT_LOG="$W/nft-calls.log"
export NFT_CONF="$W/etc/nftables.conf"
export NFT_STATE_CONF="$W/etc/nftables.d/port-forward.nft"
export MSS_CONF="$W/etc/nftables.d/mss-clamp.nft"
export SYSCTL_CONF="$W/etc/sysctl.d/99-po0-forward.conf"
SCRIPT="$T/po0-forward.sh"
rm -rf "$W"; mkdir -p "$W"

PASS=0; FAIL=0
check() {
  if [[ "$3" == *"$2"* ]]; then
    printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m %s\n       期望包含: %s\n       实际输出: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}
n_rules() {
  python3 -c "
import json
s=json.load(open('$MOCK_NFT_STATE'))
t=s['tables'].get('ip port_forward',{'chains':{}})
print(sum(len(c['rules']) for c in t['chains'].values()))" 2>/dev/null || echo 0
}
run() { bash -c 'source '"$SCRIPT"'; set +e; exec 2>&1; '"$1"; }

echo "===== T1 语法检查 ====="
bash -n "$SCRIPT" && { echo "  PASS bash -n 无语法错误"; PASS=$((PASS+1)); }

echo
echo "===== T2 输入校验 ====="
out=$(run 'for v in 1.2.3.4 256.1.1.1 1.2.3 10.100.0.10 abc; do
  if valid_ipv4 "$v"; then echo "A:$v"; else echo "R:$v"; fi; done
for p in 1 30001 65535 0 65536 abc; do
  if valid_port "$p"; then echo "A:$p"; else echo "R:$p"; fi; done')
check "IPv4 非法值拒绝" "R:256.1.1.1" "$out"
check "IPv4 非法值拒绝(段数)" "R:1.2.3" "$out"
check "端口 65535 接受" "A:65535" "$out"
check "端口 65536 拒绝" "R:65536" "$out"

echo
echo "===== T3 sysctl 合并写入（不覆盖用户已有配置）====="
mkdir -p "$(dirname "$SYSCTL_CONF")"
printf '# 用户自定义\nnet.ipv4.tcp_congestion_control=bbr\n' >"$SYSCTL_CONF"
run 'ensure_base' >/dev/null 2>&1
sysctl_content="$(cat "$SYSCTL_CONF")"
check "保留用户自定义行" "net.ipv4.tcp_congestion_control=bbr" "$sysctl_content"
check "新增 ip_forward" "net.ipv4.ip_forward=1" "$sysctl_content"
check "新增 tcp_mtu_probing" "net.ipv4.tcp_mtu_probing=1" "$sysctl_content"
check "新增 conntrack_max" "net.netfilter.nf_conntrack_max=32768" "$sysctl_content"
run 'ensure_base' >/dev/null 2>&1
dup=$(grep -c 'net.ipv4.ip_forward' "$SYSCTL_CONF")
check "重复执行不产生重复行" "1" "$dup"

echo
echo "===== T4 初始化产物（MSS 表 / 转发表 / include）====="
check "MSS 表已建" "po0_mss" "$(cat "$MOCK_NFT_STATE")"
check "转发表已建" "port_forward" "$(cat "$MOCK_NFT_STATE")"
check "nftables.conf 含 MSS include" "include \"$MSS_CONF\"" "$(cat "$NFT_CONF")"
check "nftables.conf 含转发表 include" "include \"$NFT_STATE_CONF\"" "$(cat "$NFT_CONF")"
check "MSS 文件内容正确" "maxseg size set 1452" "$(cat "$MSS_CONF")"

echo
echo "===== T5 添加转发（多私网地址 → 编号选择）====="
out=$(printf '\n30001\n10.100.0.10\n\n2\nn\n' | run 'add_rules_step_by_step')
check "列出多个候选私网地址" "1) 10.100.0.10" "$out"
check "列出第二个候选" "2) 10.0.0.5" "$out"
check "添加成功提示" "已添加并持久化" "$out"
check "规则数=2（DNAT+SNAT）" "2" "$(n_rules)"
check "SNAT 使用所选地址 10.0.0.5" "10.0.0.5" "$(cat "$MOCK_NFT_STATE")"

echo
echo "===== T6 封禁端口：拒绝则跳过 ====="
before=$(n_rules)
out=$(printf '\n443\nn\n1\n30002\n10.100.0.10\n\n1\nn\n' | run 'add_rules_step_by_step')
check "提示端口被封禁" "默认双向封禁端口" "$out"
check "拒绝后跳过该端口" "已跳过该端口" "$out"
after=$(n_rules)
check "只新增了 30002 的 2 条规则" "$((before+2))" "$after"

echo
echo "===== T7 封禁端口：确认后仍可添加 ====="
before=$(n_rules)
out=$(printf '\n8443\ny\n10.100.0.10\n\ny\n1\nn\n' | run 'add_rules_step_by_step')
check "确认后添加成功" "已添加并持久化" "$out"
check "规则数 +2" "$((before+2))" "$(n_rules)"

echo
echo "===== T8 端口冲突：报错但脚本继续运行 ====="
out=$(run 'add_one_rule tcp 30001 10.100.0.10 30001 10.100.0.10; echo "rc=$?"; echo STILL-ALIVE')
check "报入口已被占用" "入口端口已被占用" "$out"
check "返回码为 1" "rc=1" "$out"
check "脚本未被中断" "STILL-ALIVE" "$out"

echo
echo "===== T9 show / status ====="
out=$(run 'show_merged')
check "转发表包含 30001" "30001" "$out"
check "转发表包含 SNAT 列" "SNAT_TO" "$out"
out=$(run 'show_status')
check "status 显示 MSS 已启用" "已启用（maxseg 1452" "$out"
check "status 列私网地址" "10.100.0.10" "$out"

echo
echo "===== T10 检测 forward policy drop（ufw/firewalld/docker）====="
out=$(run 'nft add table ip filter
nft add chain ip filter forward "{ type filter hook forward priority 0; policy drop; }"
check_forward_policy; echo "rc=$?"')
check "检出 drop 策略" "policy drop" "$out"
check "返回码 1" "rc=1" "$out"

echo
echo "===== T11 重启模拟（全新内核状态 + 持久化文件恢复）====="
before=$(n_rules)
MOCK_NFT_STATE="$W/state_reboot.json" bash -c 'source '"$SCRIPT"'; set +e; ensure_base >/dev/null 2>&1; show_merged' >"$W/reboot.out" 2>&1
check "重启后规则条数一致" "$before" "$(MOCK_NFT_STATE="$W/state_reboot.json" n_rules)"
check "重启后 MSS 表恢复" "po0_mss" "$(cat "$W/state_reboot.json")"

echo
echo "===== T12 删除与清空 ====="
first=$(run 'extract_dnat_csv' | head -1 | cut -d, -f2)
printf '1\ny\n' | run 'delete_by_no' >"$W/del.out" 2>&1
check "删除后规则数 -2" "$((before-2))" "$(n_rules)"
printf 'y\n' | run 'clear_rules' >"$W/clear.out" 2>&1
check "清空后规则数=0" "0" "$(n_rules)"

echo
echo "===== T13 nft 调用审计（干跑校验 → 提交）====="
grep -q -- '-c -f' "$MOCK_NFT_LOG" && { echo "  PASS 存在 -c 干跑校验调用"; PASS=$((PASS+1)); }
grep -q -- 'delete table ip po0_mss' "$MOCK_NFT_LOG" && { echo "  PASS MSS 表可重复施加"; PASS=$((PASS+1)); }

echo
echo "==================================================="
printf '结果: \033[32m%d 通过\033[0m / \033[31m%d 失败\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
