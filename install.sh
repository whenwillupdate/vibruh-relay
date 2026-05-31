#!/bin/bash
set -uo pipefail

# Vibruh Relay — one-line installer
# Usage: curl -fsSL https://raw.githubusercontent.com/whenwillupdate/vibruh-relay/main/scripts/install.sh | bash -s -- user@host [-p ssh_port]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REMOTE_USER=""
REMOTE_HOST=""
SSH_PORT=22
PORT=8765

usage() {
    echo "用法: curl ... | bash -s -- user@host [-p ssh_port] [--port relay_port]"
    echo "示例: curl ... | bash -s -- xia@nies.work -p 6752"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p) SSH_PORT="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)
            if [[ "$1" == *@* ]]; then
                REMOTE_USER="${1%@*}"
                REMOTE_HOST="${1#*@}"
            fi
            shift
            ;;
    esac
done

[[ -z "$REMOTE_HOST" ]] && usage

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=5"

echo -e "${GREEN}═══ Vibruh Relay 安装器 ═══${NC}"
echo "目标: $REMOTE  SSH端口: $SSH_PORT  服务端口: $PORT"
echo ""

# ── Check SSH access ──
echo -e "${YELLOW}[1/4]${NC} 检查 SSH 连接..."
SSH_OK=$(ssh -n $SSH_OPTS "$REMOTE" "echo ok" 2>/dev/null) || true
if [ "$SSH_OK" != "ok" ]; then
    echo -e "${RED}无法 SSH 到 $REMOTE，请先配置免密登录${NC}"
    echo "  ssh-copy-id -p $SSH_PORT $REMOTE"
    exit 1
fi
echo "      SSH OK"

# ── Detect remote system ──
echo -e "${YELLOW}[2/4]${NC} 检测远程系统..."
REMOTE_UNAME=$(ssh -n $SSH_OPTS "$REMOTE" "uname -sm" 2>/dev/null)
ARCH=$(echo "$REMOTE_UNAME" | awk '{print $NF}')
KERNEL=$(echo "$REMOTE_UNAME" | awk '{print $1}')

case "$ARCH" in
    x86_64)  GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    *)       GOARCH="amd64" ;;
esac
case "$KERNEL" in
    Darwin) GOOS="darwin" ;;
    *)      GOOS="linux" ;;
esac

BIN_NAME="vibruh-relay-${GOOS}-${GOARCH}"
echo "      远程: $KERNEL/$ARCH → $BIN_NAME"

# ── Build or download binary ──
echo -e "${YELLOW}[3/4]${NC} 获取 relay 二进制..."

GH_RELEASES="https://github.com/whenwillupdate/vibruh-relay/releases/latest/download"

# Try downloading pre-built binary from GitHub Releases
echo "      尝试下载预编译版本..."
if command -v curl &>/dev/null; then
    if curl -fsSL "$GH_RELEASES/$BIN_NAME" -o "/tmp/$BIN_NAME" 2>/dev/null; then
        echo "      下载成功"
    else
        echo -e "${YELLOW}      预编译版本暂不可用，尝试本地编译...${NC}"
        
        # Fallback: build from source (requires Go + repo)
        if ! command -v go &>/dev/null; then
            echo -e "${RED}需要 Go 环境，但未找到 go 命令${NC}"
            echo "  请先安装 Go: https://go.dev/dl/"
            echo "  或将预编译二进制上传到 GitHub Releases"
            rm -f "/tmp/$BIN_NAME"
            exit 1
        fi
        
        echo "      本地编译中（需要 Git 访问仓库）..."
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        SERVER_DIR="$(dirname "$SCRIPT_DIR")/server"
        if [[ -d "$SERVER_DIR" ]]; then
            cd "$SERVER_DIR"
            CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH go build -ldflags="-s -w" -o "/tmp/$BIN_NAME" .
            echo "      编译完成"
        else
            # Clone and build
            TMPDIR=$(mktemp -d)
            git clone https://github.com/whenwillupdate/vibruh-relay.git "$TMPDIR" 2>/dev/null || {
                echo -e "${RED}无法克隆仓库，请手动部署${NC}"
                rm -rf "$TMPDIR" "/tmp/$BIN_NAME"
                exit 1
            }
            cd "$TMPDIR/server"
            CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH go build -ldflags="-s -w" -o "/tmp/$BIN_NAME" .
            rm -rf "$TMPDIR"
            echo "      编译完成"
        fi
    fi
else
    echo -e "${RED}需要 curl${NC}"
    exit 1
fi

# ── Upload & Install ──
echo -e "${YELLOW}[4/4]${NC} 上传并安装..."

# Upload binary
scp $SSH_OPTS "/tmp/$BIN_NAME" "$REMOTE:~/vibruh-relay"
rm -f "/tmp/$BIN_NAME"

# Install on remote
ssh -n $SSH_OPTS "$REMOTE" bash -s << ENDSSH
set -e

# Kill old
pkill vibruh-relay 2>/dev/null || true
sleep 1

chmod +x ~/vibruh-relay

if command -v systemctl &>/dev/null && [ -d /etc/systemd/system ]; then
    echo "      设置 systemd（开机自启 + 崩溃重启）"
    if ! sudo -n true 2>/dev/null; then
        echo "      需要 sudo 权限来创建 systemd 服务"
        echo "      请输入密码："
    fi
    if command -v sudo &>/dev/null; then
        sudo tee /etc/systemd/system/vibruh-relay.service > /dev/null <<UNIT
[Unit]
Description=Vibruh SSH Relay
After=network.target

[Service]
Type=simple
ExecStart=\$HOME/vibruh-relay
Environment=VIBRUH_PORT=$PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
        sudo systemctl daemon-reload
        sudo systemctl enable vibruh-relay
        sudo systemctl restart vibruh-relay
        sleep 2
        sudo systemctl status vibruh-relay --no-pager
    else
        # No sudo — just nohup
        nohup env VIBRUH_PORT=$PORT ~/vibruh-relay > ~/vibruh-relay.log 2>&1 &
        echo "      PID: \$!"
        echo "      ⚠️ 无 systemd，重启后需手动启动"
    fi

elif command -v launchctl &>/dev/null; then
    echo "      设置 launchd（开机自启 + 崩溃重启）"
    PLIST="\$HOME/Library/LaunchAgents/com.vibruh.relay.plist"
    mkdir -p "\$HOME/Library/LaunchAgents"
    cat > "\$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.vibruh.relay</string>
    <key>ProgramArguments</key>
    <array><string>\$HOME/vibruh-relay</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>VIBRUH_PORT</key><string>$PORT</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>\$HOME/vibruh-relay.log</string>
    <key>StandardErrorPath</key><string>\$HOME/vibruh-relay.log</string>
</dict>
</plist>
PLISTEOF
    launchctl unload "\$PLIST" 2>/dev/null || true
    launchctl load "\$PLIST"
    echo "      launchd 已加载（开机自启）"

else
    echo "      无 systemd/launchd，使用 nohup"
    nohup env VIBRUH_PORT=$PORT ~/vibruh-relay > ~/vibruh-relay.log 2>&1 &
    echo "      PID: \$!"
    echo "      ⚠️ 重启后需手动启动"
fi
ENDSSH

echo ""
echo -e "${GREEN}✅ 安装完成${NC}"
echo ""
echo "  iOS App → 设置 → 中继服务地址:"
echo "  ${REMOTE_HOST}:${PORT}"
echo ""
echo "  管理: ssh -n $SSH_OPTS $REMOTE"
