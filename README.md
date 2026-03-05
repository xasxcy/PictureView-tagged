# PictureView Tagged

**PictureView 2.3.4**（by wl879）的 Finder 颜色标签扩展，通过 `LC_LOAD_WEAK_DYLIB` 注入实现，不修改原始二进制。

原版 App：[com.zouke.PictureView](https://apps.apple.com/app/id1489900861)

---

## 已实现功能

### 右键颜色标签菜单

在以下位置右键目录可呼出颜色标签选择器：

- 侧栏目录项（PictureNav 区域）
- 画廊中的嵌套目录卡片（GalleryView 区域）

菜单底部追加一行 7 个颜色圆点，样式与 Finder 原生标签选择器一致：

- 实心填充圆点，颜色与 Finder 标准颜色标签完全一致
- 已选中标签：圆点 + 白色对勾
- 鼠标悬停：视觉高亮反馈
- 支持多个颜色标签同时选中

### 实际写入 Finder 标签

点击颜色圆点后：

1. 通过 `NSURLTagNamesKey` 写入标签名（触发 Finder UI 刷新通知，Finder 侧栏/列表视图立即显示彩色圆点）
2. 再用 `setxattr` 直接写 `com.apple.metadata:_kMDItemUserTags`，保留颜色索引（`"绿色\n2"` 格式），Finder 同时将文件夹图标渲染为对应颜色

标签使用系统当前语言的标准颜色名（`NSWorkspace.fileLabels`），在中文系统下为"红色/橙色/黄色/绿色/蓝色/紫色/灰色"，英文系统下为"Red/Orange/…"。本地卷（APFS/HFS+）和挂载卷均验证可用。

### 读取已有标签

右键菜单弹出时自动读取目标目录当前的 Finder 标签，已有标签对应的圆点显示对勾，状态与 Finder 实际一致。

### 颜色标签选择器（右键菜单）

颜色标签的设置和读取仅通过右键菜单进行。侧栏和画廊的目录图标颜色由 macOS 根据 Finder 标签自动渲染，PictureView 本身不额外叠加颜色指示点。

---

## 计划实现（未确定排期）

| 编号 | 功能 | 说明 |
|------|------|------|
| F5-A | 画廊卡片颜色回显 | 初始加载时，画廊中已有标签的目录卡片应显示颜色指示。当前仅右键后生效。难点：GalleryPictureCard 通过 CALayer 渲染，无 NSTextField 子视图，无法用文字匹配 URL |
| F5-B | 侧栏颜色回显完整覆盖 | 当前依赖 NSFileManager hook，若 PictureView 通过其他路径（如 POSIX readdir）列目录则缓存为空 |
| F6 | 多选目录批量标签 | 多选后右键显示颜色行；全部选中 → 对勾，部分选中 → 半选状态；点击批量设置/取消 |

---

## 构建方式

需要将 `PictureView.app` 安装在 `/Applications`。

```bash
# 构建补丁版 App → build/PictureView.app
bash build.sh

# 同时打包 DMG → dist/PictureView_tagged.dmg
bash build.sh dmg

# 构建并安装到 /Applications（替换原版，需要权限）
bash build.sh install
```

### 构建产物

| 路径 | 内容 |
|------|------|
| `src/PVTagPlugin.m` | 插件源码（ObjC，fobjc-arc） |
| `tools/inject_macho.py` | 向 fat Mach-O 注入 LC_LOAD_WEAK_DYLIB |
| `build/PictureView.app` | 补丁版 App（ad-hoc 签名） |
| `dist/PictureView_tagged.dmg` | 可分发 DMG |

---

## 技术说明

- 注入方式：`LC_LOAD_WEAK_DYLIB`，无需 SIP 关闭，签名后可直接运行
- PictureView 为 Swift + ObjC 混编，符号已 strip；URL 通过拦截 `NSWorkspace.activateFileViewerSelectingURLs:` 获取（Swift value type URL 无法通过 ObjC runtime 直接读取）
- 支持 Universal Binary（x86_64 + arm64），ad-hoc 签名
