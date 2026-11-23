# 解压姬

本地 Windows 解压工具：pywebview (WebView2) + Flask 做界面与后端，按密码本自动试密码并解压到同名目录。


## 启动

```
启动解压姬-Web.cmd
```

## 功能

- 拖入/选择文件，按 `passwords.txt` 密码本自动试密码解压
- 三级密码策略：进程内最小文件快速验证（.7z/.zip）→ 7z 逐个验证 → magic-extractor 暴力兜底（UI 勾选才启用）
- 命中密码自动置顶缓存（`data/hot_passwords.txt`），常用密码越解越快
- 无后缀文件自动识别真实格式、解压后折叠同名目录、可选删除源文件（回收站）

## 致谢与出处

本项目站在这些开源项目的肩膀上：

- **密码遍历核心思路移植自 [BazzaCuda/Extractor](https://github.com/BazzaCuda/Extractor)**（GPLv3，Delphi）——进程内试密码、只解压包内最小文件验证密码、命中密码置顶（move-to-front）三招均来自其 `main.pas`。本仓库相应派生逻辑遵循 GPLv3。
- **解压引擎使用 [xchwarze/magic-extractor](https://github.com/xchwarze/magic-extractor)**——按内容识别 80+ 格式的万能解压器（`magic-extractor.exe` 及其 `bin/` 下的各格式提取器均来自该项目）。
- **7-Zip**（Igor Pavlov，LGPL）——`bin/extractors/7z/`（32 位，解压与回落试密码）、`bin/extractors/7z-x64/`（64 位内核，`arc7z.py` 用 ctypes 直接调它做进程内试密码）。
- Python 依赖：pywebview、Flask、[py7zr](https://github.com/miurahr/py7zr)。

## 环境恢复

系统重装后：`pip install flask pywebview`，`pip install --target="D:\解压姬\bin\pylibs" py7zr pillow`，详见 技术栈与问题.md 的"环境依赖与重装恢复指南"。
