# frpc-manager

在 Windows 上把 frpc 装成系统服务并管理的 PowerShell 脚本。服务托管用 [NSSM](https://nssm.cc/)，可以用命令行或交互菜单完成 frpc 的下载、安装、启停、升级、改配置、看日志和清理日志。

## ✨ 功能

- **一键装成服务**：frpc 注册为 Windows 服务，开机自动启动，进程退出后 5 秒自动重启
- **自动下载 frpc**：缺少 `frpc.exe` 时会询问是否下载最新版，下载时显示进度条和网速
- **国内网络可用**：GitHub 直连失败时自动换镜像，镜像列表可以自己改；也可以手动指定版本，不访问 GitHub API
- **一键升级**：检查最新版本后自动下载、备份旧版本、替换文件，再重启服务
- **安装包保留**：下载的 zip 保留在本地，再次安装同一版本时直接使用，不重新下载
- **日志管理**：单个日志超过 10MB 自动切分，每天 03:00 由计划任务清理过期日志
- **交互菜单**：不带参数运行就打开菜单，不用记命令

## 📋 运行环境

- Windows 10 / 11 / Server 2016 及以上
- Windows PowerShell 5.1 或 PowerShell 7+
- **需要管理员权限**（安装服务和注册计划任务都要用到）
- [nssm.exe](https://nssm.cc/download)（64 位版本，需要自己下载放进目录）

## 📁 目录结构

```
frpc-manager/
├── frpc-manager.ps1     # 管理脚本
├── nssm.exe             # 需自行下载放入
├── frpc.exe             # 可自动下载
├── frpc.toml            # 首次编辑配置时自动生成模板
├── frp_x.y.z_windows_amd64.zip   # 下载后保留的安装包
├── frpc.exe.bak         # 升级时自动备份的旧版本
└── logs/
    ├── frpc.log         # frpc 主日志
    ├── frpc.out.log     # 标准输出
    └── frpc.err.log     # 错误输出
```

## 🚀 快速开始

1. 下载本仓库，把 `nssm.exe` 放到脚本所在目录
2. **以管理员身份**打开 PowerShell，进入该目录
3. 运行脚本，打开菜单：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\frpc-manager.ps1
   ```

4. 按菜单操作：
   - `1` 编辑配置文件：填写 `serverAddr`、`auth.token`、端口映射等
   - `4` 下载 frpc（目录里已有 `frpc.exe` 就跳过这一步）
   - `3` 安装并启动服务

## 🛠 命令行用法

```powershell
.\frpc-manager.ps1 <命令>
```

| 命令                                    | 说明                                                         |
| --------------------------------------- | ------------------------------------------------------------ |
| `install`                               | 安装并启动 frpc 服务                                         |
| `uninstall`                             | 停止并卸载服务，同时删除日志清理计划任务                     |
| `status`                                | 查看服务状态                                                 |
| `start` / `stop` / `restart`            | 启动 / 停止 / 重启服务                                       |
| `update`                                | 检查并升级 frpc；`frpc.exe` 不存在时下载最新版               |
| `config show`                           | 显示当前配置                                                 |
| `config get <key>`                      | 查看某个配置项，如 `config get serverAddr`                   |
| `config edit`                           | 用记事本编辑配置                                             |
| `logs [frpc\|out\|err] [行数] [follow]` | 查看日志，默认显示 `frpc.log` 最后 30 行；加 `follow` 持续跟踪 |
| `cleanlogs`                             | 手动清理过期日志                                             |
| `menu`                                  | 打开交互菜单（不带参数时默认打开）                           |
| `help`                                  | 显示帮助                                                     |

示例：

```powershell
.\frpc-manager.ps1 logs err 50          # 查看错误日志最后 50 行
.\frpc-manager.ps1 logs frpc 20 follow  # 持续跟踪主日志
```

## ⚙️ 脚本配置

脚本开头的「用户配置区」：

```powershell
$LogRetentionDays = 3          # 日志保留天数

$DownloadMirrors = @(          # 下载源，按顺序尝试
    "",                        # "" 表示 GitHub 直连
    "https://ghfast.top/",
    "https://gh-proxy.com/"
)
$DownloadTimeoutSec = 300      # 单个下载源的最长下载时间（秒）

$FrpcVersionOverride = ""      # 手动指定版本，如 "v0.61.1"；留空时自动获取最新版
```

- 在国内网络环境，建议把 `""` 移到列表最后，这样不用每次先等 GitHub 直连超时
- 公共镜像随时可能失效，失效后换成可用的镜像即可
- GitHub 完全打不开时，填上 `$FrpcVersionOverride`，脚本会跳过版本查询，直接通过镜像下载

## 📝 frpc 配置示例

第一次编辑配置时会自动生成 `frpc.toml` 模板：

```toml
serverAddr = "your.server.com"
serverPort = 7000

auth.method = "token"
auth.token = "your-token"

log.to = "./logs/frpc.log"
log.level = "info"
log.maxDays = 3

transport.tls.enable = true

[[proxies]]
name = "rdp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3389
remotePort = 6000
```

改完配置要执行 `restart` 才会生效。完整的配置项见 [frp 官方文档](https://gofrp.org/zh-cn/docs/)。

## ❓ 常见问题

**运行后出现中文乱码或语法错误**
Windows PowerShell 5.1 需要脚本保存成 **UTF-8 with BOM** 编码。在 VS Code 右下角选择编码后另存一次即可。

**提示"无法加载文件，因为在此系统上禁止运行脚本"**
用 `-ExecutionPolicy Bypass` 运行，或者执行一次：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**服务启动后连不上服务器**
先看错误日志 `.\frpc-manager.ps1 logs err`，再检查 `serverAddr`、`serverPort`、`auth.token` 和防火墙设置。

**下载进度条每次刷新都另起一行**
PowerShell ISE 不支持在同一行刷新进度。请改用普通 PowerShell 窗口、Windows Terminal 或 VS Code 终端。

**旧版本安装包占用空间**
升级后，旧版本的 `frp_*.zip` 和 `frpc.exe.bak` 不会自动删除，需要手动清理。

## 🙏 致谢

- [fatedier/frp](https://github.com/fatedier/frp)：内网穿透工具
- [NSSM](https://nssm.cc/)：Windows 服务管理器

## 📄 License

MIT
