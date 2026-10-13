# openwrt-tailscale-next

[English](README.md) · **简体中文**

OpenWrt 上的 Tailscale 插件：单页 LuCI 界面 + Tailscale 二进制自更新（sha256 校验、备份/回滚）+ 可选的定时自动更新。完全自包含——不依赖 OpenWrt 官方 `tailscale` feed 包。

## 安装

SSH 上一行命令（自动识别 opkg/apk，从最新 release 里挑对应的包）：

```sh
wget -qO- https://github.com/ywjno/openwrt-tailscale-next/releases/latest/download/install-tailscale-next.sh | sh
```

或者从 [Releases](https://github.com/ywjno/openwrt-tailscale-next/releases) 手动下载（每次 CI 同时构建两种格式；各语言包是独立的 `luci-i18n-tailscale-next-<lang>`）：

| 格式 | 适用系统 | 安装方式 |
| ---- | -------- | -------- |
| `.apk` | OpenWrt 25.12 及以上 | 先装一次 `tailscale-next.pem`（见下段），然后 `apk add luci-app-tailscale-next-*.apk` |
| `.ipk` | OpenWrt 21.02 - 24.10 | `opkg install luci-app-tailscale-next_*.ipk` |

`.apk` 是**带签名**的。设备装一次我们的公钥（LuCI：系统 → 软件包 → 配置的 Keys 区，或 SSH：`cp tailscale-next.pem /etc/apk/keys/`）之后，网页上传和 `apk add` 都不再需要 `--allow-untrusted`。装之前可先 `apk add --allow-untrusted /tmp/upload.apk` 过渡。

装完后打开"服务 → Tailscale Next"，勾选**启用**并保存：服务会自动引导安装二进制（约 10 MB 下载）。登录态和更新备份都在 `/etc/tailscale/`（sysupgrade 升级固件后保留）。

## 卸载

```sh
wget -qO- https://github.com/ywjno/openwrt-tailscale-next/releases/latest/download/uninstall-tailscale-next.sh | sh
```

已登录的话会先执行登出（登出需要守护进程还在运行），然后停止服务、卸载软件包。脚本会**刻意保留** `/etc/config/tailscale-next`（UCI 配置）、`/etc/tailscale/`（登录态 + 更新备份）、`/usr/sbin/` 下的二进制和 `tailscale-next.pem` 公钥——这些合起来仍是一套能独立运行的 Tailscale；要彻底清理请手动删除。

## 设备要求

真机实测数据；LuCI 页面的"设备要求"面板会实时显示同样的检查。

| 资源 | 最低 | 宽裕 | 说明 |
| ---- | ---- | ---- | ---- |
| 内存 | 128 MB | 256 MB | 登录后 tailscaled 常驻约 35 MB |
| 闪存 | 剩余 ~10 MB | 剩余 ~37 MB | 9 MB 二进制 + `/etc/tailscale/` 下最多 3 份备份 |
| `/tmp` | 剩余 30 MB | — | 更新器临时空间（占内存）；低内存设备用 `--workdir` 指到外置存储 |

- **zram-swap 是可选优化，不是依赖**，但它是小内存机器上最便宜的防 OOM 手段（`apk add zram-swap`；大小通过 `zram_size_mb` 配置，取物理内存一半左右即可）。
- 内存太小装不下 tailscaled 的设备也能入组网：在同网段任一台常开设备上跑 Tailscale 并广播子网（`--advertise-routes=192.168.x.0/24`，后台批准路由），整段子网都能通过它访问。

## 下载源

更新器默认从 [CH3NGYZ/small-tailscale-openwrt](https://github.com/CH3NGYZ/small-tailscale-openwrt) 的 release 下载 **UPX 压缩的合并二进制**（8–11 MB，约为官方压缩包的三分之一）：一个文件同时充当 CLI 和守护进程（按 argv[0] 分发），用该 release 的 `SHA256SUMS.txt` 校验（取不到校验和就拒绝安装）。支持 amd64 / 386 / arm / arm64 / mips / mipsle / mips64 / mips64le；**不支持 riscv64**（用 `--source official`）。

- 剩余空间 ≥ 60 MB 的设备自动安装**解压版二进制**（弱 CPU 不再每次启动都现场解压）；阈值用 `TS_VANILLA_MIN_KB` 调整。
- 镜像回退：`TS_GH_MIRRORS`（空格分隔）或 `--mirror-list <文件>`；镜像必须可信地转发未篡改的内容。
- 兜底源：`--source official [--base-url <镜像>]`（Tailscale 官方压缩包，40–90 MB）。

## 界面说明

页面共六个区块：**状态**（启用开关、登录/登出）、**全局设置**（子网路由、出口节点、主机名）、**自定义服务器**（Headscale 地址 + 认证密钥）、**更新设置**（打开页面时检查、备份份数、每天 04:30 自动更新）、**Tailscale 更新**（检查 / 更新 / 回滚 + 实时日志）、**设备要求**（内存/闪存实时判定）。

保存应用会写入 `/etc/config/tailscale-next` 并在后台重启服务；页面刷新后状态约 10 秒内就位。

## 命令行

SSH 下可独立使用（`/usr/libexec` 不在 `PATH` 里，需带全路径）：

```sh
/usr/libexec/tailscale-next-update --check            # 对比已装与最新版本
/usr/libexec/tailscale-next-update                    # 交互式更新
/usr/libexec/tailscale-next-update -y                 # 免确认
/usr/libexec/tailscale-next-update -v 1.104.1         # 指定版本
/usr/libexec/tailscale-next-update --rollback         # 回滚到上一份备份
/usr/libexec/tailscale-next-update --dry-run          # 只打印步骤
/usr/libexec/tailscale-next-update --help             # 全部选项
```

退出码：`0` 成功、`1` 错误、`3` 跳过（已有更新在跑）。常用环境变量：`TS_KEEP_BACKUPS`、`TS_VANILLA_MIN_KB`、`TS_GH_MIRRORS`（测试沙箱用的 `TS_BINDIR`/`TS_CONFDIR` 等见 `--help`）。

## 界面语言

默认英文；`luci-i18n-tailscale-next-{zh-cn, zh-tw, de, es, fr, it, ja, ko, pt-br, ru}` 跟随 LuCI 语言自动生效。要加新语言：把翻译好的 `tailscale-next.po` 放进 `luci-app-tailscale-next/po/<lang>/`，CI 会自动发现并构建。

## 构建与测试

Fork 后运行 "build OpenWrt packages" workflow（手动输入版本号，或推送 `v*` tag）——一次构建同时产出 `.ipk`（24.10.5 SDK）和 `.apk`（25.12.5 SDK）。本地构建：把 `luci-app-tailscale-next/` 拷进任意 SDK 的 `package/`，然后 `make package/luci-app-tailscale-next/compile V=s`。

任意 Linux 机器可跑沙箱测试（`sh tests/run_tests.sh`、`sh tests/test_init.sh`、`sh tests/test_i18n.sh`），仓库的 agent 说明见 `AGENTS.md`。

## 常见问题

- **更新中途失败怎么办？** 校验和不符直接拒绝安装；装完自检不通过则自动回滚到上一份备份（存在 `/etc/tailscale/.update-backup/`，0–3 份可配）。
- **版本号带后缀，如 `1.104.7-dev20261112`？** 不是开发版——上游 fork 在版本号后盖了构建日期戳；更新器只比对基础版本号。
- **低内存路由器上连续保存后状态变"未运行"？** 重叠的重启可能同时拉起两个解压实例把 daemon OOM 掉；服务脚本已做串行化（持锁时直接快速失败）。操作间隔几秒即可。
- **一直显示"另一个更新正在进行中"？** 上次更新被打断留下了陈旧状态：确认没有任务在跑后，删除 `/tmp/tailscale-next-update.status` 和 `/tmp/tailscale-next-update.lock`（30 分钟后会自动清理）。
- **更新后需要重新登录吗？** 不需要——登录态在 `/etc/tailscale/`，与二进制无关。
- **认证密钥安全吗？** 它会出现在 `tailscale up` 命令行里（`ps` 可见），和上游 LuCI 应用行为一致；路由器上本来就是 root 环境，知悉即可。
- **二进制归谁管？** 本插件的更新器管，不归 opkg/apk（如果还装了官方 tailscale 包，更新器会给它打 hold 标记）。

## 致谢

灵感与参考：[openwrt-tailscale](https://github.com/Carseason/openwrt-tailscale) 和 [small-tailscale-openwrt](https://github.com/CH3NGYZ/small-tailscale-openwrt)。

## 许可证

MIT。
