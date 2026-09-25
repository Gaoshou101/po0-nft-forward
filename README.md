# po0-forward.sh

Po0（PortChannel Zero · 腾讯云 CCN）入口机的 nftables 端口转发管理脚本。

交互式菜单增删转发规则，把客户端流量从 Po0 国内入口机（华东 / 广州 BGP）经**腾讯云 CCN 内网**转发到境外出口机：

```
客户端 → Po0 入口机（公网 IP）══ 腾讯云 CCN 内网 ══ 境外出口机 → 互联网
```

> 本脚本基于社区流传的 nftables 端口转发管理脚本改造，针对 Po0 链路补了 5 处加固。原脚本的设计（独立表、干跑校验、持久化、成对删除）予以保留。

---

## 为什么要改

通用 nftables 转发脚本在 Po0 上会踩到这几个坑：

| 坑 | 后果 |
|---|---|
| SNAT 源地址默认取默认路由的 `src`——机器把公网 IP 直接配在网卡上时就是**公网 IP** | 出口机看到的源不在 CCN 内网，回包不走内网链路 → 链路退化甚至不通 |
| 没有 MSS 钳制 | 能连上、小请求正常，但下载/看视频卡死 —— 典型 PMTU 黑洞，最难排查 |
| 不检查 Po0 封禁端口 | 把监听端口设成 `443` 后开始怀疑人生 |
| sysctl 配置文件被整体覆盖 | 手写的内核参数（如 BBR）被冲掉 |
| 单条规则出错就 `exit 1` | 批量加规则时前功尽弃 |

本脚本逐条解决。

---

## 快速开始

在 Po0 入口机上（Debian / Ubuntu，root）：

```bash
# 下载
curl -fsSL -o po0-forward.sh https://raw.githubusercontent.com/Gaoshou101/po0-nft-forward/main/po0-forward.sh
chmod +x po0-forward.sh

# 首次运行：自动安装 nftables、开启转发、启用 MSS 钳制，然后进入菜单
sudo ./po0-forward.sh
```

菜单：

```
1) 添加转发
2) 查看转发
3) 删除规则
4) 清空转发规则
5) 查看状态
0) 退出
```

也支持非交互子命令：`add` / `show` / `del` / `clear` / `status` / `help`。

---

## 添加一条转发

按提示依次填写：

| 字段 | 填什么 |
|---|---|
| 协议 | `tcp` / `udp` / `tcp+udp` |
| 入口端口 | 客户端最终连接的端口（Po0 对外监听端口） |
| **目标 IP** | 出口机 / 落地机的**公网 IP** |
| 目标端口 | 出口机协议实际监听的端口 |
| **SNAT 内网 IP** | **本机（Po0）的内网 IP** |

脚本会自动列出本机所有私网 IPv4 让你选，**不会**默认塞公网 IP。若一个私网地址都没检测到，会强制你手动填写（可回车不了）。

> **为什么这样填？** Po0 的内网互通是「目的填对端**公网** IP、源改成本机**内网** IP」：CCN 会把目的为对端公网 IP 的流量在内部送达；对端回包时看到源是本机内网 IP，也会走内网回来。两项里**只有 SNAT 源地址容易填错**，填成公网 IP 链路就会退化。

配置完成后，把客户端里的服务器地址从 `出口机IP:端口` 改成 `Po0公网IP:入口端口`，**协议、密码、加密方式保持原样**，只换地址和端口，方便排查。

### 多层链路

有自备落地机时，结构是：

```
客户端 → Po0 → RFC 中转机 → 自备落地机
```

先在落地机上搭好协议并确认直连可用，再在 RFC 中转机上做一段转发（客户端临时连 RFC 中转机验证），最后在 Po0 上把目标指向 RFC 中转机的**公网 IP**。

---

## 五处加固

1. **SNAT 源地址从本机私网地址中选取**
   多网卡时列出编号让你选；检测不到私网地址时明确警告并强制手填，绝不静默使用公网 IP。

2. **内置 MSS 钳制**
   独立表 `ip po0_mss`，`tcp flags syn tcp option maxseg size set 1452`，随开机持久化。
   同时写入 `net.ipv4.tcp_mtu_probing=1` 与 `net.netfilter.nf_conntrack_max=32768`。

3. **封禁端口强制二次确认**
   入口端口与目标端口命中 `80 / 443 / 8080 / 8443 / 8000 / 1080`（Po0 国内入口默认双向封禁）时告警，需显式确认才继续，否则跳过本条。

4. **sysctl 按 key 合并写入**
   已存在同名 key 就保留你的值，绝不整体覆盖文件，也不会重复追加。

5. **单条规则失败不中断脚本**
   端口冲突、规则校验失败只报错并返回，可继续添加下一条。

另外 `status` 会额外自检：本机私网地址、MSS 状态，以及**是否存在 `policy drop` 的 forward 链**（ufw / firewalld / docker 常见），提前发现"转发被防火墙拦掉"这类问题。

---

## 持久化机制

| 文件 | 内容 |
|---|---|
| `/etc/nftables.d/port-forward.nft` | 转发规则（脚本每次变更后重新生成） |
| `/etc/nftables.d/mss-clamp.nft` | MSS 钳制（静态） |
| `/etc/nftables.conf` | 注入两行 `include`（首次修改前自动 `cp -a` 备份） |
| `/etc/sysctl.d/99-po0-forward.conf` | 内核参数 |

重启后由 `nftables.service` 读取 `/etc/nftables.conf` 恢复。

> ⚠️ **不要和手写方案混用。** 如果你已经按官方 Wiki 手写了 `/etc/nftables.conf`（`table ip nat` + `table ip filter`），再跑本脚本会多出一张 `table ip port_forward`，两张表都挂在 `nat prerouting priority -100`，同优先级双 DNAT 匹配顺序不保证。**选一套。**

---

## 使用红线

- 需**实名认证**；**严禁用于回国访问**
- 国内入口默认封禁**双向 TCP/UDP**：`80` `443` `8080` `8443` `8000` `1080`
- 国内端不能放 web 服务
- **不要使用 Reality 等类 TLS 协议**：CCN 本不过墙，套 TLS 反而容易触发通报
- 不要装哆啦等转发面板
- 流量按**单向**统计
- 目标 IP 用出口机 / 落地机的**公网 IP**；SNAT 源地址用**本机内网 IP**——只有它能让回包走 CCN 内网

---

## 排障顺序

1. 出口机直连是否可用（Po0 只负责转发，修不了出口机自身的问题）
2. RFC 中转机转发是否可用（多层链路时）
3. Po0 转发是否可用
4. 客户端是否已换成 Po0 的公网 IP 和入口端口
5. 是否误用了封禁端口
6. `sudo ./po0-forward.sh status` —— 看 MSS 是否启用、有没有 `policy drop` 的 forward 链

---

## 环境变量

所有路径与参数都可用同名环境变量覆盖：

| 变量 | 默认值 |
|---|---|
| `NFT_CONF` | `/etc/nftables.conf` |
| `NFT_STATE_CONF` | `/etc/nftables.d/port-forward.nft` |
| `MSS_CONF` | `/etc/nftables.d/mss-clamp.nft` |
| `SYSCTL_CONF` | `/etc/sysctl.d/99-po0-forward.conf` |
| `TABLE_NAME` | `port_forward` |
| `MSS_TABLE` | `po0_mss` |
| `MSS_SIZE` | `1452` |
| `CONNTRACK_MAX` | `32768` |

---

## 测试

仓库自带离线测试：用 mock 的 `nft` / `ip` / `sysctl` / `systemctl` 做端到端验证，**不触碰真实内核**。

```bash
bash test/run.sh
```

覆盖 40 项断言：语法检查、输入校验、sysctl 合并、MSS 表与 include 生成、多私网地址选择、封禁端口拦截与放行、端口冲突后脚本继续运行、状态自检、`policy drop` 检出、重启恢复、成对删除、清空、干跑校验调用审计。

---

## 免责声明

本脚本仅做本机 nftables 规则管理，不涉及任何腾讯云控制台操作。跨境链路的合规性（企业认证、联通跨境售卖合规检查等）由 Po0 商家侧承担，使用者仍需遵守当地法律法规与商家服务条款。

参考：Po0 官方 Wiki（`wiki.uuuz.de`）的《nftables 手动转发配置》《使用前需要确认的限制》等章节。

## License

MIT
