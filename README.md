# bili-cdn-pin

**海外看B站卡顿的自动化解决方案：测出最快CDN节点并钉住它，从此视频不再卡顿。**

中文 | [English](README.en.md)


## 本分支：实际下载测速

`download-speed` 分支用视频和音频各三轮的下载速度选节点，默认每轮最多 32 MiB，保留 TLS 验证，并增加 mirrorcosov 支持。先获取新鲜媒体地址再运行原入口；使用方法、流量和恢复说明见 [实际下载测速](docs/download-speed.md)。

## 它解决什么问题

本分支测试以下海外 CDN 域名：

```
upos-hz-mirrorakam.akamaized.net    (Akamai)
upos-sz-mirroraliov.bilivideo.com   (阿里云海外)
upos-sz-mirrorcosov.bilivideo.com  (腾讯云海外)
```

这些CDN全球都有大量节点，但调度经常把你解析到远端/超载/死掉的节点——哪怕你所在城市就有3ms的本地节点（真实案例：澳洲千兆宽带默认源全线超时0 Mbps，钉住本地节点后571 Mbps）。先确认你的卡顿属于这种类型：见 [诊断指南](docs/diagnosis.md)。

本分支对候选节点逐个做视频和音频实际下载测速，把最快的IP通过 hosts / DNS重写，并定期复查：**当前节点的两类媒体下载中位数均达到 5 MB/s 就保留，低于阈值或下载失败才自动换新**。只影响这三个精确域名，不影响任何其他网站。

## 快速开始

### 本机模式（hosts，只管这台电脑）

从仓库根目录执行。需要 Python 3 和 curl；Mac 自带的命令行工具可提供 Python 3（先检查 `python3 --version`）。

macOS：

先仅测速（不需要 sudo）：

```bash
python3 tools/media-urls.py BV1Ra4y117kf --video-codec hevc &&
bash macos/bili-cdn-fix.sh --dry-run
```

正式运行（先备份 hosts/DNS，再测速和写入）：

```bash
python3 tools/media-urls.py BV1Ra4y117kf --video-codec hevc &&
sudo bash macos/bili-cdn-fix.sh
```

撤销本项目的 hosts pin：

```bash
sudo bash macos/bili-cdn-fix.sh --restore
```

这些命令可反复执行，不依赖临时文件、手动 CID 或固定 IP。媒体工具会自动取得 CID，视频详情接口返回 412 时回退到分 P 列表接口；准备失败时 `&&` 会阻止继续测速或安装。正常运行会重新选择节点，不直接安装上一次 dry-run 的结果。`--restore` 不需要媒体地址，也不修改 DNS 设置。macOS 输入 sudo 密码时终端不显示字符。

本 Mac 上发现部分 AVC 文件的 Akamai 响应提前断开，因此示例显式选择 HEVC；工具仍选择该编码下接口提供的最高带宽视频和最高带宽音频。无登录可能仅获得低清文件，文件小于 32 MiB 时下载整个文件。可替换 BVID，或使用 `--video-codec auto/avc/av1`。选择编码只影响测速资源，不改变播放器编码。冷缓存可能明显慢于后两轮，不能保证所有视频都更快。

备份位于 `/etc/hosts.bak_时间戳*`；未通过音视频全部三轮的域名保留已有配置。测试后关闭并重新打开浏览器，检查是否正常播放以及播放器统计信息。Mac 验证 hosts 应用 `dscacheutil -q host -a name upos-sz-mirrorcosov.bilivideo.com`，`nslookup` 查询 DNS 不读取 hosts。

Windows 先用同一媒体准备命令，再运行原入口：

```powershell
python tools/media-urls.py BV1Ra4y117kf --video-codec hevc
powershell -File windows/bili-cdn-fix.ps1 -DryRun
powershell -File windows/bili-cdn-fix.ps1
# 撤销：powershell -File windows/bili-cdn-fix.ps1 -Restore
```

### 服务器模式（全家生效，推荐）

家里任何一台常开设备跑 [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) 当全家DNS，脚本每周定时测速并通过API自动更新DNS重写，手机/平板/电视全部受益：

1. 常开设备装 AdGuard Home，上游DNS填 `1.1.1.1`
2. 路由器 DHCP 的 DNS 指向这台设备；设备自身DNS填 `1.1.1.1`（防环路）
3. 部署更新脚本（改开头的地址/账号/密码），每次运行前执行 `python3 tools/media-urls.py BV1Ra4y117kf --video-codec hevc` 刷新媒体地址，再加每周日 04:30 定时任务（保持仓库目录结构）：
   - 群晖：DSM 任务计划，root 运行 `bash /path/to/server/bili-agh-update.sh >> /path/to/bili-agh.log 2>&1`
   - Mac mini / Debian：`sudo crontab -e` 加 `30 4 * * 0 /bin/bash /path/to/server/bili-agh-update.sh >> /path/to/bili-agh.log 2>&1`（macOS记得关睡眠）
   - Windows常驻机：任务计划程序运行 `windows\bili-agh-update.ps1`
4. 验证：`nslookup upos-hz-mirrorakam.akamaized.net 设备IP` 应返回钉住的IP

### 路由器模式（OpenWrt/梅林，最轻量）

dnsmasq 把路由器 `/etc/hosts` 的记录答复给全局域网，无需AdGuard：

```sh
opkg install curl
# 先在电脑运行媒体准备命令，将仓库及 media/*.url 复制到路由器；每次测试需刷新地址
sh openwrt/bili-openwrt-update.sh
# crontab -e 加：30 4 * * 0 /root/bili-openwrt-update.sh >> /root/bili-cdn.log 2>&1
```

## 目录结构

```
windows/bili-cdn-fix.ps1        本机模式（hosts）
windows/bili-agh-update.ps1     服务器模式（AdGuard API，Windows常驻机）
macos/bili-cdn-fix.sh           本机模式（hosts）
server/bili-agh-update.sh       服务器模式（AdGuard API，群晖/macOS/Debian通用）
openwrt/bili-openwrt-update.sh  路由器模式（dnsmasq hosts）
docs/                           诊断指南 / FAQ / 排坑指南
```

## 文档

- [诊断指南](docs/diagnosis.md)——先分清你是"CDN家族选错"还是"节点分配错"，两种问题及解决方案
- [FAQ](docs/faq.md)——更新频率、影响范围、手机App、节点失效等常见问题
- [排坑指南](docs/troubleshooting.md)——副DNS轮换、RDNSS漏网、IPv6误区、DoH绕过、油猴不生效、逐层验证方法

## 致谢

- IP种子列表与思路来源：[miyouzi/akamTester](https://github.com/miyouzi/akamTester)
- CDN域名切换方案：[Kanda-Akihito-Kun/ccb](https://github.com/Kanda-Akihito-Kun/ccb)

## License

MIT
