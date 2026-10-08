# Easy-proxy

一个用于开发和下载的统一 HTTPS 代理，支持 GitHub、Hugging Face、PyPI 等公网 HTTPS 服务。无需修改仓库地址、下载链接、`HF_ENDPOINT` 或 pip 源。

```text
Git / curl / Python / pip / Hugging Face
             │ HTTP CONNECT，127.0.0.1:17890
       Easy-proxy 本机客户端
             │ TLS 加密 + 用户认证
       Easy-proxy 服务器 :443
             │ CONNECT 隧道，公网目标 :443
          HTTPS 目标网站
```

服务器使用 IP 和独立私有 CA；客户端验证代理证书，目标网站的 HTTPS 仍由原工具验证。**不用把私有 CA 安装进系统，也不会解密目标 HTTPS 内容。** 本机入口没有认证，仅绑定回环地址；同一台机器上的其他进程也可以使用它。

加速效果取决于客户端到服务器、服务器到目标网站的网络质量。本项目提供转发路径，不提供缓存或固定倍数的提速保证。

## 1. 下载与服务端部署

服务器要求：Ubuntu 22.04 / 24.04 或 Debian 12 / 13、systemd、root 管理权限。Linux amd64、arm64 均提供预编译文件；安装不需要 Go、Docker。安装工具依赖 `bash`、`coreutils`、`util-linux`、`iproute2`、`passwd`；在线升级另需 `curl` 和 `ca-certificates`。

从 [Releases](https://github.com/Funny-Rainbow/Easy-proxy/releases) 下载对应架构的压缩包及 `SHA256SUMS`。以首版 amd64 为例：

```bash
version=v0.1.0
base="https://github.com/Funny-Rainbow/Easy-proxy/releases/download/$version"
curl -fL -O "$base/easy-proxy_${version}_linux_amd64.tar.gz"
curl -fL -O "$base/SHA256SUMS"
grep "  easy-proxy_${version}_linux_amd64.tar.gz$" SHA256SUMS | sha256sum -c -
tar -xzf "easy-proxy_${version}_linux_amd64.tar.gz"
sudo ./easy-proxy install --host YOUR_SERVER_IP --port 443
sudo easy-proxy doctor
```

`--host` 是客户端连接的服务器 IP，用于证书 IP SAN；绑定地址默认 `0.0.0.0:443`。IPv6 服务器地址亦可使用，监听时显式传入 `--listen '[::]:443'`。通过 SSH 上传真正的发布包后执行安装，也适用于服务器暂时不能访问 GitHub 的情况。

如果 `443` 已占用，选择其他端口，例如 `--port 8443`。安装会检测冲突，不会停止已有代理或 Web 服务。重复安装保留配置、密码和 CA；修改已安装监听地址时，编辑 `/etc/easy-proxy/server.json` 后运行 `sudo easy-proxy restart`。

安装后在服务器或云控制台放行所选 **TCP** 端口。工具不自动修改防火墙，也不申请域名证书。

导出客户端配置：

```bash
sudo easy-proxy export-client --out /root/client.json
# 本地执行，使用你实际的 SSH 用户和端口：
scp root@YOUR_SERVER_IP:/root/client.json ./client.json
```

`client.json` 含密码和 CA 公钥，不含 CA 私钥。请通过可信 SSH 等通道传输，不要提交到 Git。CA 私钥保存在服务器 `/etc/easy-proxy/ca-key.pem`，只有 root 可读。

## 2. Linux / WSL 客户端

下载并解压对应 Linux 发布包，保存 `client.json`。先在一个终端启动前台桥接：

```bash
chmod 600 client.json
./easy-proxy client run --config ./client.json
```

在另一个终端启用代理；辅助脚本可从本仓库 `scripts/` 或 Releases 下载：

```bash
source scripts/client-env.sh
easy_proxy_enable

curl -I https://github.com
git clone https://github.com/Funny-Rainbow/Easy-proxy.git
python -m pip install requests

easy_proxy_disable
```

启用只修改当前终端的 `HTTPS_PROXY`、`https_proxy`、`NO_PROXY`、`no_proxy`；取消时恢复原值，不写 `.bashrc` 或全局 Git 配置。已有终端需分别启用。自定义本机监听地址时，导出配置使用 `export-client --listen 127.0.0.1:PORT`，终端对应使用 `easy_proxy_enable 127.0.0.1:PORT`。

可选：安装为当前用户的 systemd 服务，自动随用户会话启动：

```bash
./easy-proxy client install --config ./client.json
./easy-proxy client status
./easy-proxy client stop
./easy-proxy client start
./easy-proxy client uninstall
```

此方式需要运行中的 systemd 用户会话。WSL 未启用 systemd 时使用 `client run` 即可；无需改变 WSL 设置。用户服务默认随登录启动，退出最后一个会话后的运行行为由系统的用户会话策略决定。

## 3. Windows 客户端

下载 `easy-proxy_v0.1.0_windows_amd64.zip` 和 `SHA256SUMS`，用 `Get-FileHash` 核对 ZIP 的 SHA-256 后解压。

在一个 PowerShell 终端运行：

```powershell
.\easy-proxy.exe client run --config .\client.json
```

在另一个 PowerShell 终端启用代理：

```powershell
. .\scripts\client-env.ps1
Enable-EasyProxy

curl.exe -I https://github.com
git clone https://github.com/Funny-Rainbow/Easy-proxy.git
python -m pip install requests

Disable-EasyProxy
```

使用 `curl.exe`，避免 Windows PowerShell 5.1 的 `curl` 别名。PowerShell 脚本只修改当前进程环境，不修改 Windows 系统代理设置。限制本地脚本执行的机器可在当前会话按自己的策略加载脚本。

可选后台安装：

```powershell
.\easy-proxy.exe client install --config .\client.json
.\easy-proxy.exe client status
.\easy-proxy.exe client stop
.\easy-proxy.exe client start
.\easy-proxy.exe client uninstall
```

后台安装创建当前用户登录时运行的计划任务，配置及程序保存在 `%LOCALAPPDATA%\Easy-proxy`，目录 ACL 限制为当前用户和 SYSTEM。某些组织策略禁止普通用户创建计划任务，此时使用前台模式。卸载删除本项目任务和安装文件；已启用代理的终端另行执行 `Disable-EasyProxy`。

Windows 和 WSL 可各自运行客户端；分别在相应终端启用代理，避免依赖两者的 localhost 转发设置。前台使用的原始 `client.json` 由用户保管，后台卸载只删除安装目录中的副本。

## 4. Hugging Face、Git、Docker

Hugging Face 使用正常地址和原有身份认证：

```python
from huggingface_hub import snapshot_download
snapshot_download("bert-base-uncased")
```

Python `requests` / `httpx` 可通过环境变量连接本机代理。Hugging Face 的 Xet 下载器随版本变化，无法保证所有版本使用 `HTTPS_PROXY`；若 Xet 绕过代理或下载失败，在启动 Python 之前设置：

```bash
export HF_HUB_DISABLE_XET=1
# PowerShell: $env:HF_HUB_DISABLE_XET = '1'
```

无需设置 `HF_ENDPOINT`。Git 必须使用 `https://github.com/...` 地址；`git@github.com:...` 属于 SSH，不通过本项目转发。GitHub/Hugging Face 的 Token 与代理账号独立，仍按工具原来的方式配置。

Linux Docker daemon 不继承终端环境。保持这台 Linux 机器上的本机客户端运行，执行：

```bash
sudo bash scripts/docker-proxy.sh enable
# 应用配置需要重启 Docker，会影响运行中的容器：
sudo systemctl restart docker
docker pull alpine

# 取消：
sudo bash scripts/docker-proxy.sh disable
sudo systemctl restart docker
```

脚本只管理 `docker.service.d/easy-proxy.conf`，不改其他 Docker 配置。长期运行 Docker 时，需要为本机客户端安排持续运行的用户会话。

Docker Desktop 在 Settings → Resources → Proxies 中手动设置 HTTPS 代理。仅当 Desktop 的代理组件能访问本机桥接端口时可填 `http://127.0.0.1:17890`；不同后端的回环网络行为不同，使用 Desktop 的代理测试确认。此项目不自动修改 Desktop 设置，也不提供 Registry Mirror。

## 5. 升级、回滚和卸载

```bash
sudo easy-proxy status
sudo easy-proxy doctor
sudo easy-proxy restart
journalctl -u easy-proxy -n 100 --no-pager

# 明确指定版本，校验发布包和配置后切换：
sudo easy-proxy upgrade --version v0.1.1
# 离线上传发布包和 SHA256SUMS 后：
sudo easy-proxy upgrade --version v0.1.1 --from /path/to/packages
sudo easy-proxy rollback

sudo easy-proxy renew-cert
sudo easy-proxy rotate-password
sudo easy-proxy export-client --out /root/client.json

# 停止并移除程序/服务，保留配置、密码及 CA：
sudo easy-proxy uninstall
# 再次使用发布包 install，会复用保留状态。
# 连同配置、证书和版本备份一起删除：
sudo ./easy-proxy uninstall --purge
```

示例中的 `v0.1.1` 表示未来存在的目标版本。升级默认从本仓库 Releases 获取，也支持 `--base-url https://YOUR_RELEASE_HOST/path`。校验文件与发布包通过 HTTPS 从同一可信来源获取；SHA-256 用于发现损坏，不等同于独立的发布签名。

升级保留一个可回滚版本及配置备份。新版本启动失败或管理命令遇到可捕获的中断，会恢复先前版本和配置；`SIGKILL`、断电无法运行恢复代码，重启后可检查 `current` 链接和 `previous-version` 手动恢复。升级、回滚、续证会重启代理并中断现有隧道，下载工具可通过 Range 重试恢复。

v1 没有配置迁移，主动回滚保留当前密码及证书。配置包含 `schema`，未知版本会被拒绝，防止旧程序错误读取新配置。服务证书有效期一年；`doctor` 在剩余不足 30 天时提示，`renew-cert` 保留原 CA。私有 CA 有效期十年，替换 CA 需要重新分发配置，首版不自动续期。

密码轮换后重新分发配置；后台客户端可停止并卸载后用新配置安装，或停止后替换安装目录配置并重新启动。客户端升级同样使用停止、卸载、重新安装流程。服务端升级和客户端升级相互独立。

卸载保留独立系统服务账号，避免 UID 被其他账号复用；不会卸载系统依赖或删除原有代理服务。需要完全清理时可在 `--purge` 后由管理员移除闲置 `easy-proxy` 系统账号。

## 6. 检查连接与故障定位

无需先启动本机桥接即可测试远端连接：

```bash
./easy-proxy probe --config ./client.json
```

依次期望 GitHub API `200`、Hugging Face `200`、Docker Registry `401`（正常认证挑战）。网站限流、地域限制或服务状态变化也会导致检查失败；此命令不测下载速度。

- 无法连接：检查服务器地址、TCP 端口、防火墙和 `easy-proxy status`。
- TLS 失败：检查客户端 CA 与服务器匹配、服务器 IP 未变、系统时间正确、证书未过期。不要关闭证书验证。
- CONNECT 失败：检查密码和目标端口；第一版仅允许公网 `443`，私网、回环、链路本地和特殊地址会被拒绝。
- 工具没有走代理：确认在启动工具前启用当前终端环境；GUI、浏览器、已运行进程、忽略环境变量的 SDK 需各自配置 HTTP 代理。
- 代理已停但工具仍连接旧端口：执行当前终端的取消函数，或恢复自己手动设置的环境变量。

`doctor` 检查服务、证书和监听，`probe` 检查实际出站。普通日志不记录密码、代理认证头、目标 URL、下载查询参数或网站 Token。

## 7. 开发与发布

Go 1.25+，仅标准库，无第三方 Go 依赖：

```bash
go test -race ./...
go vet ./...
bash scripts/test-shell.sh
# Windows: powershell -File scripts/test-env.ps1
bash scripts/build.sh v0.1.0
```

发布包位于 `dist/`。开发调试无需 root：

```bash
mkdir -p .local
go build -o .local/easy-proxy ./cmd/easy-proxy
.local/easy-proxy init --dir "$PWD/.local/state" --host 127.0.0.1 --port 18443 --listen 127.0.0.1:18443
.local/easy-proxy pki-export --dir "$PWD/.local/state" --out .local/client.json
.local/easy-proxy server --config .local/state/server.json
# 另一个终端：
.local/easy-proxy client run --config .local/client.json
```

自动测试覆盖双层加密代理、认证和 CA 失败、DNS 校验与地址固定、IPv4/IPv6 限制、大文件、Range、持续流式下载、连接限制及清理、CA 续证和环境恢复。部署生命周期测试只能在一次性 systemd 机器或容器中执行：

```bash
docker build -f scripts/Dockerfile.systemd-test -t easy-proxy-systemd-test .
docker run -d --name easy-proxy-test --privileged --cgroupns=private --tmpfs /run --tmpfs /tmp -v "$PWD:/workspace:ro" easy-proxy-systemd-test
docker exec -e EASY_PROXY_DISPOSABLE_TEST=1 easy-proxy-test bash /workspace/scripts/test-systemd.sh
docker rm -f easy-proxy-test
```

CI 在 Linux / Windows 运行测试，在 Debian / Ubuntu systemd 容器验证安装、重复安装、升级失败恢复、升级、回滚、续证、轮换及卸载。推送 `vX.Y.Z` 标签会在测试通过后自动构建并发布三平台包、校验文件及客户端脚本。不会自动部署服务器。
