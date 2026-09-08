# Paste

一个轻量的 macOS 剪贴板历史工具。Swift + AppKit 原生实现，常驻菜单栏，物理内存占用约 20 MB。

- 自动记录复制的**文本和图片**，SQLite 持久化，默认保留最近 2000 条
- **`Option + X`** 唤起面板，展示最近的复制记录
- 输入即搜索，`↑` `↓` 选择，**回车或单击直接粘贴**到当前输入框
- `⌘ ⌫` 删除选中记录，`Esc` 关闭面板
- 相同内容再次复制自动去重并置顶
- 自动忽略密码管理器等标记为敏感的内容
- 菜单栏提供「登录时启动」「清空所有记录」

## 安装

### 方式一：下载安装包

1. 到 [Releases](https://github.com/yantl0/paste/releases) 页面下载最新的 `Paste-x.y.z.zip`
2. 解压，把 `Paste.app` 拖到「应用程序」文件夹
3. 首次打开会提示「无法验证开发者」，这是因为本项目没有购买 Apple 开发者账号做公证。处理方法任选其一：
   - 双击打开一次并关闭提示，然后到 **系统设置 › 隐私与安全性**，在底部点「仍要打开」
   - 或者在终端执行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/Paste.app
     ```
4. 打开后菜单栏出现剪贴板图标，按 `Option + X` 即可使用

### 方式二：从源码编译

需要 macOS 13 及以上，并安装 Xcode 或 Xcode 命令行工具（Swift 5.9+）。

```bash
git clone https://github.com/yantl0/paste.git
cd paste
./build.sh
open build/Paste.app
```

`build.sh` 会用 `swift build -c release` 编译并打包成 `build/Paste.app`，默认使用 ad-hoc 签名（无证书，永不过期）。
开发调试时可以用 `./build.sh --dev`，它会用本机的开发者证书签名，这样重新编译后不需要重新授予辅助功能权限。

## 首次运行：授予辅助功能权限

「点击记录直接粘贴」需要向当前应用发送 `Cmd + V`，macOS 要求授予**辅助功能**权限。

1. 首次启动时系统会弹出授权提示
2. 前往 **系统设置 › 隐私与安全性 › 辅助功能**，勾选 Paste
3. 菜单栏图标的菜单里可以看到当前授权状态

未授权时点击记录只会复制到剪贴板，需要手动粘贴。`Option + X` 快捷键本身不需要该权限。

> 注意：`Option + X` 会覆盖该组合键原本输入「≈」的功能。

## 使用

| 操作 | 按键 |
| --- | --- |
| 打开 / 关闭面板 | `Option + X` |
| 搜索 | 直接输入 |
| 上下选择 | `↑` `↓` |
| 粘贴选中项 | `回车` 或 鼠标单击 |
| 删除选中项 | `⌘ ⌫` |
| 关闭面板 | `Esc` |

## 内存控制

- 面板一次只从 SQLite 读取最近 200 条的摘要（预览文本前 200 字、时间、尺寸），正文按需读取
- 图片原图以 PNG 存到磁盘，数据库只存一张不超过 96 像素的缩略图；面板最多缓存 60 张缩略图，关闭即释放
- SQLite 页缓存限制 256 KB，WAL 模式
- 单张图片原始数据超过 30 MB 不记录，单条文本超过 1 MB 不记录
- 在 Finder 中复制文件不记录（只记录文本和图片）

## 数据位置

```
~/Library/Application Support/Paste/paste.sqlite
~/Library/Application Support/Paste/images/
```

卸载时删除 `Paste.app` 和上述目录即可。

## 项目结构

```
Package.swift
Resources/Info.plist          应用 Bundle 信息（LSUIElement 隐藏 Dock 图标）
Sources/Paste/
  main.swift                  入口
  AppDelegate.swift           菜单栏、组件装配
  ClipboardMonitor.swift      轮询剪贴板、图片转 PNG 与缩略图
  Store.swift                 SQLite 存储、搜索、去重、清理
  HotKey.swift                Carbon 全局快捷键
  Paster.swift                辅助功能权限、模拟 Cmd+V
  PanelController.swift       弹窗面板 UI
Resources/AppIcon.icns        应用图标（由 scripts/make_icon.swift 生成）
scripts/make_icon.swift       用 CoreGraphics 绘制图标并输出 1024px PNG
build.sh                      编译并打包 .app
```

## 为什么不上 App Store

App Store 要求沙盒，而沙盒禁止向其他应用发送键盘事件，「点击直接粘贴」这个核心功能会失效。

## License

MIT
