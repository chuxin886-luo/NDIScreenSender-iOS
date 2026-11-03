@echo off
chcp 65001 >nul
title NDI 链路自测
cd /d "%~dp0"
echo 发送彩条测试画面，用于验证 NDI 链路是否通（不需要手机）
echo 在 Nixsense / NDI Studio Monitor 里找源 "iOS Screen"
echo.
python ndi_bridge.py --selftest
pause
