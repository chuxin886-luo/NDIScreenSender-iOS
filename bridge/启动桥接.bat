@echo off
chcp 65001 >nul
title NDI Bridge - iOS -> NDI
cd /d "%~dp0"

echo ============================================
echo   iOS 投屏 -> NDI 桥接
echo ============================================
echo.

where python >nul 2>nul
if errorlevel 1 (
    echo [!] 没找到 python，请先安装 Python 3.10+ 并勾选 Add to PATH
    pause
    exit /b 1
)

python -c "import av" >nul 2>nul
if errorlevel 1 (
    echo [*] 首次运行，安装依赖 av / numpy ...
    python -m pip install -r requirements.txt
    if errorlevel 1 (
        echo [!] 依赖安装失败，手动执行: python -m pip install av numpy
        pause
        exit /b 1
    )
)

echo [*] 启动桥接（Ctrl+C 停止）
echo.
python ndi_bridge.py %*

pause
