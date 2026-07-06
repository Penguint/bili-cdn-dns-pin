# FAQ

**多久更新一次合适？**
每周一次足够。节点质量以周/月为单位变化，脚本又有"≤60ms不动"的阈值，测太勤没有意义。突然全家变卡就手动跑一次。

**会影响其他网站吗？**
不会。hosts/DNS重写是精确匹配完整域名，这两个域名全球只有一个用途：给B站传视频。`akamaized.net` 下其他子域名（其他网站的资源）不受影响。

**本机模式能加速全家吗？**
不能，hosts只对本机生效，其他设备不会来查你电脑的hosts。全家生效必须用服务器模式（任何常开设备都行：NAS、Mac mini、Debian盒子、常开PC、OpenWrt路由器）。

**同时用了本机hosts和服务器模式怎么办？**
删掉本机hosts那份（`-Restore` / `--restore`）。hosts优先级高于DNS，留着会压过服务器每周自动更新的结果，变成两套互相打架的配置。例外：经常外出的笔记本可保留hosts当出门兜底。

**手机App还是卡？**
B站App部分请求走自带的 HTTPDNS，会绕过本地DNS，DNS方案对App可能只部分生效。可尝试拦截HTTPDNS逼App回退系统DNS：AdGuard订阅 [miaoermua/AdguardFilter](https://github.com/miaoermua/AdguardFilter) 拦域名类；路由器防火墙 REJECT `203.107.1.0/24`（阿里HTTPDNS）拦IP直连类，完整清单见 [GetSomeFries HTTPDNS wiki](https://github.com/VirgilClyne/GetSomeFries/wiki/%F0%9F%9A%AB-HTTPDNS)。仍不行则只剩回国加速器。

**仓库里的IP列表是通用的吗？**
只是种子列表。每个人的最优IP取决于城市和ISP，脚本会结合实时DNS解析补充候选并实测，**务必自己跑，不要抄别人的结果**。

**钉住的节点会不会突然失效？**
会（CDN会下线节点）。表现为B站突然大面积加载失败。定时任务下次运行时自动换节点；等不及就手动跑一次，或 restore 撤销回退到普通DNS。

**为什么不测下载速度而只测连接延迟？**
TCP连接延迟测得快、对B站服务器无额外流量压力，且与观感高度相关（本地节点延迟低通常吞吐也足）。追求极致可参考 akamBiliChecker 的下载测速思路，代价是每次测试要拉取真实视频流量。
