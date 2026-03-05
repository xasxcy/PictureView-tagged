# PRD: PictureView Finder Tag 功能

## 背景

PictureView 2.3.4 是一款已停更 4 年的 macOS 闭源图片浏览器（by wl879）。用户希望为其添加 macOS Finder 颜色标签功能，方便在浏览大量图片目录时快速标记和分类。

本项目通过 dylib 注入（非破解）的方式实现功能扩展。

## 功能需求

### F1: 右键菜单添加标签颜色行

- **触发位置 1**：右键侧栏目录项（PictureNav 区域）
- **触发位置 2**：右键主区域嵌套目录卡片（GalleryView 区域）
- 在原有右键菜单底部添加一行 7 个颜色圆点（Red, Orange, Yellow, Green, Blue, Purple, Gray）
- **不是二级子菜单**，而是直接在菜单中罗列颜色圆点，与 Finder 原生标签选择器一致

### F2: 标签颜色样式（与 Finder 一致）

- 7 个实心填充圆点，颜色与 Finder 原生标签颜色完全一致
- 未选中状态：实心圆，标准饱和度
- 已选中状态：实心圆 + 白色对勾（checkmark）
- 鼠标悬停：轻微视觉反馈（如亮度提升或边框）
- 支持多选（可同时设置多个颜色标签）

### F3: 实际设置 Finder 标签

- 点击颜色圆点后，通过 `NSURLTagNamesKey` API 实际写入 macOS Finder 标签
- 标签设置需持久化到文件系统（需支持 HFS+/APFS 卷宗；对于不支持 xattr 的卷宗，需要有错误提示或 fallback）
- 再次点击已选中的颜色可取消该标签

### F4: 读取并显示已有标签

- 右键弹出菜单时，读取目标目录当前已有的 Finder 标签
- 已有标签对应的颜色圆点显示为选中状态（带白色对勾）
- 保证标签状态与 Finder 实际状态一致

### F5: 文件夹图标颜色同步

- 在 PictureView 的 UI 中，已设置标签的目录应当显示对应颜色的文件夹图标
- 侧栏目录项和主区域目录卡片都需体现标签颜色
- 如果目录在 Finder 中已有标签颜色，PictureView 中也应显示
- 注意：这需要在 PictureView 的渲染层面做修改（如 swizzle 文件夹图标绘制）

## 非功能需求

- 注入方式：LC_LOAD_WEAK_DYLIB，通过 `build.sh` 一键构建
- 不修改原始二进制文件（仅在 build/ 目录操作）
- 最终交付物为 DMG 包（`dist/PictureView_tagged.dmg`）
- 支持 Universal Binary（x86_64 + arm64）
- ad-hoc 签名

## 当前实现状态

| 功能 | 状态 | 备注 |
|------|------|------|
| F1: 右键菜单标签行 | Done | 侧栏 + 主区域均可触发 |
| F2: Finder 风格样式 | Partial | 已有圆点 + 对勾，颜色待微调至与 Finder 完全一致 |
| F3: 实际设置标签 | Bug | `setResourceValue` 返回成功但标签未持久化（可能是卷宗兼容性问题） |
| F4: 读取已有标签 | Partial | 菜单打开时读取 `currentTags(url)`，但未在所有场景验证 |
| F5: 文件夹图标颜色 | Not Started | 需要 swizzle 图标绘制逻辑 |

## 技术约束

- PictureView 是 Swift + ObjC 混编，符号已 strip
- Scanner 类的 `url` ivar 是 Swift URL value type（size=0），无法通过 ObjC runtime 直接读取
- URL 获取通过拦截 NSWorkspace.activateFileViewerSelectingURLs: 实现（程序化触发"在访达中打开"按钮获取 NSURL）
- Foundation._SwiftURL 是纯 Swift 类（非 NSURL 子类），不暴露任何 ObjC 方法
