# 修复 ZL2 / FCL 的登录弹窗与下载进度条跑到屏幕下方

测试目标：iPhone X（A11, 375×812 pt @3x，刘海 + 34pt Home Indicator）、iOS 16.7.15、TrollStore Lite + Dopamine。

## 现象

ZL2（Zalith Launcher 2）与 FCL（Fold Craft Launcher）在 Husk 的 translation layer 下：

- 微软账号登录弹窗大部分落在屏幕外面下方，点不到、登不上；
- 下载核心 / 模组的进度条也在底部看不见。

两者都不是独立 bug：一个是宿主把弹窗定位到物理底边，另一个是 Java framework 给这些窗口上报了 0 insets。

## 根因（按调用链）

1. **宿主只在 launch 时发一次 safe-area insets**（`TLUnityView.launch()` → `husk_java_set_insets`）。视图刚被加进 window 时 `window.safeAreaInsets` 可能还是 0；之后旋转、状态栏变化都不会重发。于是 `husk.ViewRoot.sInsets` 长期为 `{0,0,0,0}`，Java 侧完全不知道底部有 34pt 的 Home Indicator。
2. **`ViewRoot.computeInsets()` 对非全屏窗口直接返回全 0 insets**（只剩 ime）。ZL2 是 Compose、FCL 是 View/Compose 混合，登录 BottomSheet、Scaffold 的 bottomBar / Snackbar 全靠 `WindowInsets.navigationBars` 定位，拿到 0 就贴到物理底边。
3. **`ViewRoot.performLayout()` 对浮窗没有位置/尺寸约束**：`wrap_content` 用整屏高度 `AT_MOST` 测量，decor 可能比可见区还高；`Gravity.BOTTOM` 按 `out.bottom = area.bottom - yAdj` 计算，负的 `y` 偏移（PopupWindow / BottomSheet 常见）或过大的高度会把窗口推到屏幕下方；`drawAll()` 在 `sCanvas` 边界裁剪，超出的部分直接消失，看起来就是「弹窗在屏幕外面下面」。
4. **`WebView.updateFrame()` 把 `getLocationOnScreen()` 的结果原样交给 native WKWebView**。窗口位置错了，登录页的原生视图也跟着跑到屏幕外。

## 改动

| 文件 | 改动 |
|---|---|
| `src/app/Husk/TLUnityView.swift` | 新增 `pushJavaInsets()`：在 `didMoveToWindow` / `layoutSubviews` / `safeAreaInsetsDidChange` / 键盘事件都重发 insets；`window.safeAreaInsets` 为 0 时回退到 key window；保留键盘高度不再被覆盖 |
| `src/java-framework/src/husk/ViewRoot.java` | 浮窗不再返回 0 insets，而是上报与其位置互补的 status/nav/ime；`wrap_content` 浮窗尺寸被限制到屏幕内；`Gravity.apply` 之后把窗口 clamp 进屏幕；位置变化后重新分发 insets，避免重复避让 |
| `src/java-framework/src/android/webkit/WebView.java` | 原生 WKWebView 帧 clamp 到屏幕内，OAuth 登录页始终可达 |
| `scripts/package_ipa.sh` | 新增 `--trollstore-a11`：A11 无 PPL/TXM，保留 `dynamic-codesigning` 等 JIT entitlement（原先 `--trollstore` 一律剥掉，会让 ART 退化成解释模式） |
| `scripts/ci_build.sh` | 同时产出 `Husk.tipa`（A12+）与 `Husk-a11.tipa`（iPhone X） |
| `scripts/verify_java_framework.sh` | 新增：用 javac 全量编译 Java framework 的快速校验，不需要 d8 / Xcode / QEMU |
| `.github/workflows/husk-build.yml` | push / PR 跑快速校验；`workflow_dispatch` 可触发完整 IPA 构建并上传 artifact |

**刻意不动**：density 计算（`A.cfg.density = contentScaleFactor`，默认 High=2，与 surface 像素一致）、游戏全屏窗口路径（`g == 0` 直接全屏，clamp 只作用于浮窗）、`barsHidden()` 沉浸模式分支。

## 验收（真机，必须做）

1. SideStore / TrollStore Lite 装 `Husk-a11.tipa`；iOS 16.7.15 需要先 Dopamine 越狱，重启后重新越狱。
2. 冷启动确认 JIT 横幅消失（`dynamic-codesigning` 自持，或 `apple-magnifier://enable-jit?bundle-id=...`）。
3. ZL2：设置 → 全局渲染器 → 登录微软账号 → 弹窗四边完整在屏内、不被刘海 / Home Indicator 遮挡；取消能 dismiss。
4. ZL2 / FCL：下载任意游戏核心，进度条完整可见、不被 Home Indicator 压住。
5. 键盘唤起时页面只上移键盘高度，不整体漂移；横竖屏切换后弹窗仍 clamp 在屏内。
6. `TL_VIEW_DUMP=1` 抓 `ViewDump` 日志，断言 `decor.bottom <= screenH()` 且 `WindowInsets.bottom > 0`（非沉浸模式）。

## 已知限制

- **本仓库改动未经真机验证**：显示效果依赖 ZL2/FCL 具体版本与 Compose 的 insets 消费方式，需按上面的清单实测；编译由 GitHub Actions 验证。
- `husk-tl-bionic-ndk.c` 的 `AConfiguration.density` 仍硬编码 480（3x），而默认 High 档是 2x（320dpi）。Java UI 走 `A.cfg.density` 不受影响；若某个启动器的 native 层读 `AConfiguration_getDensity()` 出现尺寸偏差，再把它接成运行时值。
- 账号登录能否完成还取决于 OAuth 回调 scheme / WKWebView 回调，本次只修显示位置。
- 只要 IPA 仍链接 QEMU，整体仍是 GPLv2 组合作品，不能上 App Store；AOSP/Apache-2.0 与 GPL 并存边界见 `docs/01-licensing.md`。

## 构建

```sh
# 快速校验（Mac / GitHub Actions）
HUSK_JDK="$(/usr/libexec/java_home -v 17)" bash scripts/verify_java_framework.sh

# 完整 IPA（需要 Xcode + meson/ninja/xcodegen/qemu-img/Rust aarch64-apple-ios）
HUSK_JDK="..." HUSK_D8=".../r8.jar" ./scripts/ci_build.sh
```

GitHub Actions：push 到 `fix/**` 自动跑 `verify`；手动 `workflow_dispatch` 选 `full_ipa=true` 跑完整构建，产物在 Actions 的 `Husk-display-fix` artifact。
