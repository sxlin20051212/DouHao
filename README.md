# ， DouHao — macOS 休息提醒工具

<p align="center">
  <img src="https://raw.githubusercontent.com/sxlin20051212/DouHao/main/douhao/%EF%BC%8C.png" alt="DouHao" width="128">
</p>

<p align="center">
  <strong>定时休息，保护眼睛</strong>
</p>

<p align="center">
  <a href="https://github.com/sxlin20051212/DouHao/releases"><img src="https://img.shields.io/github/v/release/sxlin20051212/DouHao?style=for-the-badge" alt="GitHub release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?style=for-the-badge" alt="macOS 13+">
  <img src="https://img.shields.io/badge/language-SwiftUI-orange?style=for-the-badge" alt="SwiftUI">
</p>

---

**逗号** 是一个轻量级的 macOS 菜单栏休息提醒应用。设定时间间隔后，它会在菜单栏安静地倒计时，时间到了弹出提醒窗口，提醒你站起来活动、喝水、远眺——给你的工作流加一个"逗号"，停顿一下。

纯 SwiftUI 原生开发，内存占用极小，常驻菜单栏不占 Dock。

---

## 功能

| 功能 | 说明 |
|------|------|
| ⏱ **自定义间隔** | 自由设定分钟+秒数，精确到秒 |
| 🔔 **自定义提醒语** | 弹出窗口显示你写的文字，比如「起来走走」「喝水」 |
| 🌊 **心流模式** | 倒计时到后先闪烁屏幕边缘，闪烁 N 次后才弹窗提醒，不打断心流 |
| 📐 **渐进式提醒** | 每次提醒后自动缩短间隔（减半 or 固定减少），提醒越来越频繁 |
| 🔗 **绑定 App** | 绑定某个 App，打开即自动开始计时 |
| 🔄 **继续时自动重启** | 点击继续后自动开始新一轮倒计时 |
| 🕵 **休息时检测活动** | 结束休息后检测鼠标/键盘活动，有动静自动恢复计时 |
| 📊 **统计** | 今日专注时长 + 休息次数 |

---

## 安装

### 下载 DMG

前往 [Releases](https://github.com/sxlin20051212/DouHao/releases) 页面下载最新版 `.dmg` 文件。

1. 打开 DMG，把 `，.app` 拖到 `Applications` 文件夹
2. 首次打开时，如果 macOS 提示"无法验证开发者"：
   - 打开 **系统设置 → 隐私与安全性**
   - 在底部找到「，」并点击 **仍要打开**
3. 菜单栏会出现「，」图标，点击即可设置

> 最低系统要求：**macOS 13 (Ventura)** 及以上

### 从源码编译

```bash
git clone git@github.com:sxlin20051212/DouHao.git
cd DouHao
swift build -c release
```

---

## 使用

1. 点击菜单栏的 **「，」** 图标
2. 设置倒计时间隔（默认 60 分钟）
3. 可选：开启心流模式、渐进式提醒
4. 点击 **▶ 开始计时**
5. 时间到弹出提醒窗口，点击「我知道了」后可以选择继续或结束

---

## 界面

<p align="center">
  <img src="https://raw.githubusercontent.com/sxlin20051212/DouHao/main/douhao/%EF%BC%8C.png" alt="逗号" width="400">
</p>

---

## 技术栈

- Swift 5.9+
- SwiftUI
- AppKit (NSStatusBar, NSWindow, CGEvent)
- 无第三方依赖

---

## 许可

MIT License
