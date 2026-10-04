# 实际下载测速（download-speed 分支）

本分支保留原来的 Mac hosts、Windows hosts、OpenWrt hosts 和 AdGuard DNS 重写入口。覆盖 Akamai、mirroraliov 和 mirrorcosov；不依赖播放器因 DNS 屏蔽而自动回退，也不把 TCP 延迟作为速度。

## 自动获取媒体地址

直接运行原入口即可。Mac/Linux/OpenWrt 用 curl + jq；Windows 用 PowerShell 的原生 JSON 解析，运行不需要 Python。OpenWrt 安装 `curl jq ca-bundle`，并保留完整仓库目录结构。

入口每次自动获取 CID 和新鲜签名地址；详情接口失败时回退到分 P 列表。默认测速视频为 `BV1Ra4y117kf`、编码为 HEVC，可设置 `BILI_BVID`、`BILI_VIDEO_CODEC`（auto/hevc/avc/av1）和可选 `BILI_CID`。选择编码只影响测速资源，不改变播放器编码。

分别选择该编码下最高带宽的视频和最高带宽音频，并优先使用各 CDN 自己的原始签名地址。无登录可能只获得低清文件；文件小于请求范围时下载整个文件。获取失败则退出，保留已有 pin。Shell 的签名地址只存在本次运行的临时目录，退出后清理；Windows 保存在内存中。恢复操作跳过媒体获取。

高级用法：同时提供 `BILI_VIDEO_URL` 和 `BILI_AUDIO_URL` 可跳过自动获取；设置 `BILI_USE_MEDIA_FILES=1` 可使用 `BILI_MEDIA_DIR` 下自行准备的 `.url` 文件。地址会过期，不要提交签名或 cookie。

## 先仅测试

```bash
bash macos/bili-cdn-fix.sh --dry-run
BILI_DRY_RUN=1 bash server/bili-agh-update.sh
BILI_DRY_RUN=1 sh openwrt/bili-openwrt-update.sh
```

Windows：

```powershell
powershell -File windows/bili-cdn-fix.ps1 -DryRun
powershell -File windows/bili-agh-update.ps1 -DryRun
```

确认后仍用原来的正常运行命令。Mac 的 `--restore`、Windows 的 `-Restore` 保留；OpenWrt 新增 `--restore`。Mac 正常运行重新测速，写入前在 hosts 旁备份 hosts、系统 DNS 信息、网络服务与当前服务的 DNS 服务器（默认 Wi-Fi，可设 `BILI_NETWORK_SERVICE`），不改变 DNS；其他 hosts 入口也写入前备份。未测出可用节点的域名保留已有记录。AdGuard 仍使用原来的 API 和状态文件；新节点添加失败时尝试恢复旧记录。

现在入口需要 `common/` 目录，部署时保留仓库目录结构，不能只复制单个脚本。AdGuard 和路由器定时任务直接调用原入口，每次自动刷新媒体地址。

## 测量与选取

- 每个候选分别下载视频和音频，默认各三轮、串行，避免自身下载竞争带宽。
- 每次请求前 32 MiB；源文件更小时取到文件末尾，日志显示实际字节数。可通过 `BILI_SPEED_BYTES` 调大。
- 保持原域名的 Host、SNI 和正常证书验证；用 `curl --resolve` 指向候选，不使用 `-k`。不跟随重定向，也不通过系统代理测速。
- 要求 curl 成功、HTTP 206、Content-Range 从 0 开始，字节数等于请求范围与文件大小的较小值。任一轮失败、超时、证书错误或下载不完整，候选不参与排名。
- 视频与音频各取中位数；同一个域名只能固定一个 IP，所以取两个中位数中较低值作为该节点得分，分数越高越优先。日志单位为 bytes/s。
- 保留原来的定期健康复查框架，但将阈值改成实际吞吐：默认两个媒体都达到 5 MB/s 就保留当前节点，低于阈值再重选。设 `BILI_KEEP_BPS=0` 不会强制重新比较；要重选可移除状态中的旧 pin，或设置更高阈值。
- 候选仍来自原来的种子列表，并通过 Cloudflare DoH 补充新 IP，避免路由器重定向使候选查询只返回固定 IP/0.0.0.0。mirrorcosov 使用实时候选；shell 可用 `BILI_COSOV_IPS` 补充种子。
- 只有缺少该 CDN 原始地址时，才使用通用地址。当源媒体 URL 来自别的受支持 CDN 时，只替换 URL 主机，保留路径和签名；目标服务不支持该资源会被正常响应检查排除，不保证跨 CDN 兼容。

设置：`BILI_SPEED_ROUNDS`（至少 3）、`BILI_SPEED_BYTES`（默认 33554432）、`BILI_SPEED_TIMEOUT`（每轮默认 60 秒）、`BILI_KEEP_BPS`、`BILI_MEDIA_DIR`，或直接提供 `BILI_VIDEO_URL` 和 `BILI_AUDIO_URL`。shell 还可用 `BILI_DOMAINS`、`BILI_CANDIDATE_IPS` 缩小测试范围。

全量流量上限约为“候选数 × 轮数 × 视频和音频请求大小”。短文件、热点视频和重复下载会受缓存影响，不能证明所有视频、冷门视频或全天候都更快。部署前应比较默认 DNS 和固定节点的实际播放，并撤销同一域名的 DNS 屏蔽；hosts 测试恢复后再验证路由器，以免本机 hosts 覆盖 DNS 重写。

验证：`python3 tests/test_download_speed.py` 使用 curl 替身检查双媒体中位数、失败淘汰及各 shell 入口的 dry-run；Python 仅用于开发测试，不是运行依赖；Windows 代码需要在 Windows 上运行验证。
