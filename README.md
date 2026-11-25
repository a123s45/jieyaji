# 解压姬

本地 Windows 解压工具：pywebview (WebView2) + Flask 做界面与后端，按密码本自动试密码并解压到同名目录。

## 运行前提（依赖清单）

| 依赖 | 版本 / 说明 | 是否需要自己装 |
|---|---|---|
| Windows | 10 / 11，64 位 | — |
| Python | 3.10 及以上，**推荐 3.14** | 要 |
| Flask | `>=3.0` | 要（见 `requirements.txt`） |
| pywebview | `>=5.4`，Windows 上走 Edge WebView2 | 要（见 `requirements.txt`） |
| WebView2 Runtime | Win11 自带；Win10 若缺，装 Evergreen Runtime | 可能要 |
| PowerShell | 5.1（系统自带），`extract-worker.ps1` 靠它跑 | 不用 |
| 7-Zip | 已随仓库打包：`bin/extractors/7z/`（x86）、`bin/extractors/7z-x64/`（x64 内核，`arc7z.py` 用） | **不用** |
| magic-extractor | 已随仓库打包：`magic-extractor.exe` + `bin/` 下各格式提取器 | **不用** |
| py7zr / pillow / psutil / pycryptodomex / brotli | 已随仓库放在 `bin/pylibs/`（**cp314** 编译） | **不用**（Python 不是 3.14 时才 `pip install py7zr pillow`） |

> 真正需要 pip 装的只有 `flask` 和 `pywebview`，其余二进制都在仓库里。
> `bin/pylibs` 里的 `.pyd` 是 cp314 的，所以 Python 3.14 最省事；用别的版本程序照样能跑
> （试密码走 `7z.dll` 的 ctypes 通道，不依赖这些 .pyd），只是少一层纯 Python 回落。

## 第一次运行

```bat
pip install -r requirements.txt
启动解压姬-Web.cmd
```

启动器会在 PATH 和常见安装位置里找一个「能 import flask + webview」的 Python，不写死安装路径；一个都找不到会提示该装什么。

**密码本不随仓库发布**（`passwords.txt` 被 `.gitignore` 排除，避免把自己的密码表传上去）。
首次运行会自动建一个空文件；想直接开跑，复制一份示例：

```bat
copy passwords.example.txt passwords.txt
```

之后可以用侧栏「导入新密码」逐条加，命中的密码会自动写回并置顶缓存。

## 功能

- 拖入/选择文件，按 `passwords.txt` 密码本自动试密码解压
- 三级密码策略：`7z.dll` 进程内最小文件快速验证（zip/7z/rar/rar5）→ 7z 逐个验证 → magic-extractor 暴力兜底（UI 勾选才启用）
- 命中密码自动置顶缓存（`data/hot_passwords.txt`），常用密码越解越快
- 多线程批量（默认 4 路，另有「自动」档按 CPU 核数收敛），分卷自动只取首卷
- 无后缀文件自动识别真实格式、解压后折叠同名目录、可选删除源文件（回收站）

## 目录结构（挑要紧的）

```
jieyaji_web.py           Flask 后端 + pywebview 窗口、任务调度（线程池）
webui/index.html         单页 UI
extract-worker.ps1       单个压缩包的解压 / 试密码 worker（路径全部相对脚本目录）
pwtest.py                试密码入口：arc7z(7z.dll) → py7zr → 由 worker 回落 7z 循环
arc7z.py                 ctypes 手写 7z.dll 的 COM 封装（进程内试密码）
bin/extractors/          各格式解压器（7z、unrar、peazip…）
bin/pylibs/              vendored Python 依赖（cp314）
```

## 致谢与出处

本项目站在这些开源项目的肩膀上：

- **密码遍历核心思路移植自 [BazzaCuda/Extractor](https://github.com/BazzaCuda/Extractor)**（GPLv3，Delphi）——进程内试密码、只解压包内最小文件验证密码、命中密码置顶（move-to-front）三招均来自其 `main.pas`。本仓库相应派生逻辑遵循 GPLv3。
- **解压引擎使用 [xchwarze/magic-extractor](https://github.com/xchwarze/magic-extractor)**——按内容识别 80+ 格式的万能解压器（`magic-extractor.exe` 及其 `bin/` 下的各格式提取器均来自该项目）。
- **7-Zip**（Igor Pavlov，LGPL）——`bin/extractors/7z/`（32 位，解压与回落试密码）、`bin/extractors/7z-x64/`（64 位内核，`arc7z.py` 用 ctypes 直接调它做进程内试密码）。
- Python 依赖：pywebview、Flask、[py7zr](https://github.com/miurahr/py7zr)。

## 环境恢复（换机器 / 重装后）

```bat
pip install -r requirements.txt
:: Python 不是 3.14 时，再补一份纯 Python 依赖
pip install py7zr pillow
```

`bin/` 和 `magic-extractor.exe` 都在仓库里，不用另外下载。详见 `技术栈与问题.md` 的「环境依赖与重装恢复指南」。
