#!/bin/zsh
# 双击运行：在刘海下方放一块彩色背景，展开面板，好看清玻璃的折射
APP="$HOME/Applications/Limen.app"
[ -d "$APP" ] || APP="$(cd "$(dirname "$0")" && pwd)/build/Limen.app"

pkill -x Limen 2>/dev/null
sleep 0.5
"$APP/Contents/MacOS/Limen" --glass-demo --fake >/dev/null 2>&1 &
sleep 1.2
echo "已启动玻璃演示：面板展开，背后是彩色的测试背景。"
echo "· 点底部齿轮可以切换玻璃样式（通透 / 标准 / 磨砂 / 专辑）"
echo "· 点底部电源图标退出"
echo
read -k 1 "?按任意键关闭此窗口（应用继续运行）..."
