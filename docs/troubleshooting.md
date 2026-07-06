# 排坑指南

实战中踩过的坑，按出现频率排序。

## 副DNS不要填公共DNS

DHCP里主DNS填了AdGuard、副DNS填 1.1.1.1？多数系统会在主副DNS之间**轮换**而非只在故障时切换——查到公共DNS头上的请求绕过了重写，表现为加速"时灵时不灵"。

副DNS留空，或填同一台AdGuard。代价是DNS服务器宕机期间全家无DNS（NAS常开+容器自动重启的话风险很小）。

## 设备DNS里冒出 fe80::1（RDNSS漏网）

改了DHCP的DNS，`nslookup` 却显示 `Server: fe80::1`？这是运营商路由器通过 **RA（RDNSS）/ DHCPv6** 向设备通告了自己当IPv6 DNS，IPv6 DNS优先级高于IPv4，你的AdGuard被晾在一边。

修复顺序：

1. 路由器关闭 DHCPv6 Server 和 RA 的 O 标志（如果固件允许且不影响地址分配）
2. 固件关不干净的（RA里内嵌RDNSS）：用**路由器静态解析表兜底**——不少固件支持静态"域名→IP"条目（如中兴 H1600 在 Local Network → DNS → Host Name），把CDN域名和钉住的IP填进去。设备无论问AdGuard还是问路由器，答案一致，漏网也无所谓
3. 静态条目是死的，配合脚本的 `ROUTER_DNS` 检查（见下节）在过期时收到提醒

Windows侧刷新顽固的IPv6 DNS：`ipconfig /release6; ipconfig /renew6`，不行就重启网卡。

## 路由器静态条目的同步告警（ROUTER_DNS）

`server/bili-agh-update.sh` 顶部把 `ROUTER_DNS` 设为路由器IP（如 `192.168.20.1`，留空跳过）。每次运行时脚本核对路由器的答案与当前钉住IP是否一致；不一致或无应答时发DSM桌面通知并以错误码退出。

配合群晖：控制面板 → 通知设置 → 电子邮件启用后，任务计划里勾选「仅当任务异常终止时通过电子邮件发送运行详情」——路由器条目过期时自动收邮件，日志写明应更新的新IP。

## IPv6三大误区

- **关闭路由器的IPv6 DNS下发 ≠ 关闭IPv6**：设备地址来自RA/SLAAC，照常获得全球v6地址、照常走v6流量；只是DNS查询改走IPv4问AdGuard，AAAA记录照常返回。"用什么协议查DNS"和"用什么协议访问网站"是两码事
- **DNS能查到AAAA ≠ IPv6通了**：连通性用 https://test-ipv6.com 验证
- **LAN侧设置弄不坏WAN侧IPv6**：如果路由器状态页显示WAN的IPv6卡在"Connecting"、GUA为空，那是和运营商的协商问题（重启路由器重拨；无效则联系ISP），与LAN配置无关

## 浏览器"安全DNS"（DoH）绕过一切

nslookup正常但浏览器里不生效？浏览器开了"安全DNS"会直连DoH服务商，绕过系统DNS和hosts。到浏览器隐私设置里关掉，或实测确认你的浏览器版本是否遵守hosts。

## CCB油猴脚本装了没反应

- 新版Chrome/Edge需要在扩展管理页开启**开发者模式**（部分版本还需要在Tampermonkey详情页单独开"允许用户脚本"），然后完全重启浏览器
- 脚本只对安装后**新加载**的页面生效，老标签页要强制刷新（Ctrl+F5）
- 脚本菜单只在**匹配的页面**（视频/直播/番剧页）上出现，个人空间页、首页上是灰的

## 逐层验证方法

用 `nslookup <域名> <服务器IP>` 指定服务器逐层排查：

```
nslookup upos-hz-mirrorakam.akamaized.net <AdGuard IP>   # 第一层：应答钉住的IP
nslookup upos-hz-mirrorakam.akamaized.net <路由器IP>      # 第二层：应答一致
nslookup upos-hz-mirrorakam.akamaized.net                # 第三层：默认DNS，看设备实际问谁
```

三层都对，最后在B站播放器里右键「视频统计信息」看真实生效的Host。
