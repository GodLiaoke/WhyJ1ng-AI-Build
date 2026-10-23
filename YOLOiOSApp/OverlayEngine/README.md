# AuthCore 悬浮组件（SpringBoard 半身）

系统级悬浮窗 + 屏幕识别 + 触摸注入。
和鉴权逻辑**在同一个二进制里**：`AuthCore.dylib`，一个二进制、两个宿主。
交付形态：**deb 包**，Sileo 点安装或 `dpkg -i`。

---

## 0. 先说三件最容易搞错的事

1. **deb 必须装。** 没装 = App 启动 10 秒后自己退出（见第 5 节）。
2. **不需要往任何游戏里注入东西。** filter 只指向 `com.apple.springboard`，
   游戏进程里没有我们一行代码。装一次，对所有 App 生效。
3. **用的是屏幕内容，不是摄像头。**

---

## 1. 为什么必须跑在 SpringBoard 里

App 自己的 `UIWindow` 只在**本进程**的合成层里排序。App 切到后台 → 系统挂起进程 →
SpringBoard 不再合成它的窗口。`windowLevel` 调多高都没用，这是结构限制。

SpringBoard 的窗口天然在所有 App 之上，而且 SpringBoard 永远不会被挂起。
所以识别闭环（抓屏 → Core ML → 画框 → 注入拖动）全部在 SpringBoard 内完成：

```
AuthCore.dylib
├── 被 App 加载（IPA 内置 Frameworks/AuthCore.dylib，@rpath）
│     └─ 鉴权：AuthCoreIsLoaded / Version / Integrity / Verify   ← 行为不变
│
└── 被 SpringBoard 加载（deb 装到 /usr/lib，filter 指向 com.apple.springboard）
      └─ 悬浮引擎：抓屏 + YOLO 推理 + 透明悬浮窗 + 触摸注入
```

构造函数里判断自己在哪个进程，走不同分支。App 侧**没有**完整数据通路：
瞄准发生时前台是游戏、App 已被挂起，它跑不了推理、抓不了屏、也没有注入权限。
两边唯一的通道是一份 plist 加心跳文件。

---

## 2. 适用范围

| 环境 | 系统版本 | 结果 |
|---|---|---|
| **Dopamine**（rootless） | iOS 15.0 – 16.6.x | ✅ 装 `_iphoneos-arm64.deb` |
| **palera1n**（rootful / rootless） | iOS 15 – 16.x | ✅ 按越狱模式选包 |
| **unc0ver / checkra1n**（rootful） | iOS 15 – 16.x | ✅ 装 `_iphoneos-arm.deb` |
| 其他真越狱（ElleKit / Substitute 系） | iOS 15 – 26.0.1 | ⚠️ 能注入即可用；26.x 的抓屏 / HID 符号**需真机验证** |
| **只有 TrollStore** | iOS 14 – 17.0 | ❌ **做不到** |
| 未越狱 | 任意 | ❌ 做不到 |

### 2.1 TrollStore 为什么单独用不行

- TrollStore 给的是「不签名安装 + platform-application 权限」，只对 **App 本体**有效。
- **它没有 SpringBoard 注入能力。**
- **TrollFools 这类工具只能注入普通 App 的进程**，不能注入 SpringBoard。
  注进 App 的结果是：dylib 跑在 App 进程里，App 一切到后台被挂起，悬浮窗照样消失。
- 所以「巨魔模式下悬浮窗在本 App 内能用、切出去就没了」不是悬浮窗写坏了，
  是结构上不可能。想在 TrollStore 设备上用，唯一的路是**先越狱**。

因为 TrollStore 设备上装不了这个 deb，第 5 节的自动退出对 TrollStore 设备**不生效**
（否则 App 在这类设备上会永久不可用）。

---

## 3. 产物与安装

| 文件 | 说明 |
|---|---|
| `cc.ouovo.authcore_1.1.0_iphoneos-arm.deb` | **rootful**：`/usr/lib/`、`/Library/MobileSubstrate/DynamicLibraries/` |
| `cc.ouovo.authcore_1.1.0_iphoneos-arm64.deb` | **rootless**：`/var/jb/usr/lib/`、`/var/jb/Library/MobileSubstrate/DynamicLibraries/` |

**为什么出两个包**：rootless 设备的系统卷是只读密封的，带 rootful 路径的包在那种机器上
解包阶段就会失败。两个包把路径直接烘进去，装哪个一目了然。

每个包含：

```
DEBIAN/control             Package: cc.ouovo.authcore / Architecture / Depends
DEBIAN/postinst            清旧心跳 → 修权限 → sbreload（或 killall SpringBoard）
DEBIAN/prerm               卸载时重启 SpringBoard
DEBIAN/md5sums
<prefix>/usr/lib/AuthCore.dylib
<prefix>/Library/MobileSubstrate/DynamicLibraries/AuthCore.dylib
<prefix>/Library/MobileSubstrate/DynamicLibraries/AuthCore.plist   ← filter: com.apple.springboard
```

`AuthCore.plist` 与 `AuthCore.dylib` 必须同名同目录：MobileSubstrate 系的加载器
按「`X.plist` 对应同目录的 `X.dylib`」去找。

### 3.1 安装

```bash
# Sileo / Zebra：把 deb 传进设备（AirDrop / Filza / scp），点开 → 安装

# 命令行
dpkg -i cc.ouovo.authcore_1.1.0_iphoneos-arm64.deb   # rootless
dpkg -i cc.ouovo.authcore_1.1.0_iphoneos-arm.deb     # rootful
```

`postinst` 会自己 respring。没生效就手动：

```bash
killall -9 SpringBoard      # 或 sbreload
```

### 3.2 手动安装（不用 deb，排查时用）

```bash
# rootless
scp authcore/AuthCore.dylib YOLOiOSApp/OverlayEngine/AuthCore.plist \
    root@DEVICE:/var/jb/Library/MobileSubstrate/DynamicLibraries/
ssh root@DEVICE 'chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/AuthCore.dylib; killall -9 SpringBoard'

# rootful
scp authcore/AuthCore.dylib YOLOiOSApp/OverlayEngine/AuthCore.plist \
    root@DEVICE:/Library/MobileSubstrate/DynamicLibraries/
ssh root@DEVICE 'chmod 755 /Library/MobileSubstrate/DynamicLibraries/AuthCore.dylib; killall -9 SpringBoard'
```

---

## 4. 装完怎么验证（30 秒）

心跳文件是这个组件唯一的存在证明。装完等 5 秒：

```bash
ls -la /var/mobile/Library/Preferences/cc.ouovo.authcore.alive
```

- **文件出现** → 已注入 SpringBoard 并在跑。确认时间戳是新的：
  ```bash
  cat /var/mobile/Library/Preferences/cc.ouovo.authcore.alive; date +%s
  ```
  两个数字应在 5 秒以内（unix 秒，纯数字、无换行）。
- **文件不存在** → 看日志：
  ```bash
  cat /var/mobile/Library/Preferences/cc.ouovo.authcore.log
  ```
  **连日志都没有** = dylib 没被加载。查三件事：路径对不对、
  `AuthCore.plist` 是否同目录且 filter 指向 `com.apple.springboard`、dylib 有没有 arm64e 切片。

日志关键行：

```
component 1.1.0 starting in SpringBoard (iOS ...)   ← 加载成功，进对了进程
capture: render=... iosurface=... ready             ← 抓屏可用
capture: CARenderServerRenderDisplay returned N     ← 抓屏被拒（权限）
hid: ... ready                                      ← 注入可用
detector: 已加载 · 输入 image · 640x640              ← 模型加载成功
overlay: window installed at level 1000000          ← 悬浮窗已建
```

### 4.1 三步自检

1. 心跳文件存在且时间戳在更新 = 组件活着
2. 打开任意 App（相册 / 游戏），悬浮框仍在 = 系统级生效
3. 悬浮框区域能正常点到下面的 App = 窗口没挡触摸

### 4.2 心跳写了三份

| 路径 | 谁读 |
|---|---|
| `/var/mobile/Library/Preferences/cc.ouovo.authcore.alive` | 主心跳，越狱设备上 App 和人都能读 |
| `.../Containers/Data/Application/<UUID>/Documents/cc.ouovo.authcore.alive` | **App 读这份**（沙盒内，离线可用） |
| `/var/mobile/Library/Preferences/cc.ouovo.yolooverlay.alive` | 旧名字，兼容合并前的 App 构建 |

`<UUID>` 是 SpringBoard 遍历 `.../Application/*/.com.apple.mobile_container_manager.metadata.plist`、
读 `MCMMetadataIdentifier` 等于 `com.yolo.person.YOLOiOSApp` 找到的那个容器。

App 侧判断顺序：自己 Documents 里的 → 主心跳 → 旧名字。
导出的 `AuthCoreSystemHeartbeatAge()` 就是这么算的。

---

## 5. App 侧接口与“不装就退出”

### 5.0 卡密第二次校验（dylib 自己查）

App 在激活时问一次服务器，结果存在自己的 defaults 里 —— 那是**最容易被 patch 掉**的地方。
所以 dylib 会再查一次，用的是同一张卡：

```
POST https://ios.ouovo.cc/api/lic/dylib        （明文 JSON，豁免传输层加密）
{ device_id, card_code, ipa_verdict, nonce, ts,
  sig = HMAC-SHA256("device_id|card_code|nonce|ts", dylib.secret) }
```

- 密钥是**编译进 dylib 的常量**（XOR 0x5A 掩码，`strings` 拿不到明文；CI 里有断言守着）。
  这是共享密钥方案，不是安全边界 —— 伪造者还得先有一张有效卡密。
- **缓存 5 分钟**，只为性能。过窗即失效，下一次调用必须联网重查。
- **网络失败 = 失败**。没有“离线先放行”。
- **没有宽恕期**。服务端 `grace.hours=0`、`offline.allowed=0`。
- `ipa_verdict` 把 App 自己的判定带上去，服务端可比对：
  「App 说有效、服务端说卡被撤销」= App 侧判定被改过。

校验失败时引擎的行为：

| 情况 | 结果 |
|---|---|
| plist 里还没有卡密 | 悬浮引擎**不启动**，日志写明原因，每 60 秒重试 |
| 卡无效 / 被封 / 过期 | 同上 |
| 签名/配置错误、服务端拒绝 | 同上 |
| 网络不通 | 同上（不是“先放行”） |
| 运行中校验失效 | 立刻停抓屏、隐藏悬浮窗 |

**心跳照写**。心跳证明的是「deb 装了、组件在跑」，和「卡密有效」是两件事：
卡坏了不该让 App 以为组件没装。

导出的接口：`AuthCoreSubmitCard` / `AuthCoreLicenseValid` / `AuthCoreLicenseAge` /
`AuthCoreLicenseLevel` / `AuthCoreLastLicenseResult` / `AuthCoreSyncLicense`
（Swift 侧走 `AuthCoreBridge*` 包装）。

### 5.1 新增导出（`AuthCoreBridge.h`，全部 `weak_import`）

```c
bool   AuthCoreSystemAvailable(void);      // 组件在跑，心跳 < 15 秒
double AuthCoreSystemHeartbeatAge(void);   // 距上次心跳秒数，-1 = 从没见过
bool   AuthCoreComponentRequired(void);     // 这台设备上「缺组件」算不算故障
```

Swift 侧走 `AuthCoreBridgeSystemAvailable()` / `AuthCoreBridgeSystemHeartbeatAge()` /
`AuthCoreBridgeComponentRequired()` 三个安全包装。

**`AuthCoreIsLoaded()` 不能用来判断 deb 是否装了** —— 它只说明 App 内置的那份加载了。
系统组件在不在，只能看心跳。

### 5.2 自动退出的规则

构造函数在 App 进程里起一个 10 秒定时器，到点后：

```
组件可用                          → 什么都不做
TrollStore 设备                   → 不做（装不了 deb，不能因此废掉 App）
非越狱设备（没有越狱痕迹）          → 不做（本来就装不了 deb）
真越狱 + 组件缺失                  → 写日志，exit(0)
```

用 `exit(0)` 而不是 `abort()`：App 必须停下来，但没必要制造一份栈回溯和真正原因
毫无关系的崩溃报告。

`YOEngineStart()` 在 App 进程里是空操作：引擎自己也会检查宿主，只认 SpringBoard。

---

## 6. 配置

App 写入，组件读取。

```
配置文件   /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.plist
Darwin 通知 cc.ouovo.yolooverlay.reload      收到后 0.3 秒去抖，重读并重建
日志       /var/mobile/Library/Preferences/cc.ouovo.authcore.log（256 KB 轮转）
```

### 6.1 键

| 键 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `enabled` | bool | `true` | 总开关 |
| `overlay` | bool | `true` | 是否画框 |
| `aim` | bool | **`false`** | 是否注入瞄准（移动用户手指，默认关） |
| `autoAim` | bool | `true` | 用**自己**的检测结果自动瞄准（`aim` 为 true 时才生效） |
| `modelPath` | string | `""` | `.mlmodelc` 绝对路径 |
| `confidence` | real | `0.35` | 置信度阈值 |
| `headHeightFraction` | real | `0.22` | 框顶往下多少比例算头部 |
| `headWidthFraction` | real | `0.5` | 头部水平位置 |
| `speed` | real | `1.0` | 速度倍率 |
| `smoothing` | real | `0.35` | 平滑（越大越稳越迟钝） |
| `boxColor` | string | `#2563EB` | 框颜色，`#RRGGBB` 或 `#RRGGBBAA` |
| `captureFPS` | real | `15` | 抓屏+推理帧率上限，钳在 5–30 |
| `maxBoxes` | int | `4` | 每帧最多画几个框 |
| `onlyPerson` | bool | `true` | 只取 person 类（class 0） |
| `hidScale` | real | `0` | 点→数字转换系数，`0` = 用屏幕 scale |
| `pendingDx` | real | — | **App 写 / 组件消费并清零**：水平位移（点） |
| `pendingDy` | real | — | **App 写 / 组件消费并清零**：垂直位移（点） |

瞄准点取**头部**而不是框中心：从框顶往下取 `headHeightFraction` 高的一条带，
再取这条带的中间；水平位置由 `headWidthFraction` 决定（0.5 = 正中）。
与 App 内 `AimSettings` 的几何完全一致。

### 6.2 模型

`modelPath` 指向 **已编译** 的 `.mlmodelc`（`.mlpackage` 不行，组件不会现场编译）：

```bash
xcrun coremlcompiler compile yolo11s.mlpackage outdir/    # -> outdir/yolo11s.mlmodelc
```

推荐位置（任选一个，组件按顺序找）：

```
/var/jb/Library/Application Support/YOLOOverlay/yolo11s.mlmodelc      # rootless
/var/mobile/Library/Application Support/YOLOOverlay/yolo11s.mlmodelc
/var/mobile/Documents/YOLOOverlay/yolo11s.mlmodelc
```

模型要求同 App 里那份：带图像输入的 YOLO 导出（`nms=False`），输出
`[1, 4+类别数, anchors]` 或 `[1, anchors, 4+类别数]` —— 两种排布都能识别。

### 6.3 App 写不进配置文件时

部分越狱环境下 App 仍是沙盒进程，写不了 `/var/mobile/Library/Preferences/`。
组件照样加载、照样写心跳，只是用默认值。手动放一份：

```bash
cat > /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>enabled</key><true/>
  <key>overlay</key><true/>
  <key>aim</key><true/>
  <key>autoAim</key><true/>
  <key>modelPath</key><string>/var/mobile/Documents/YOLOOverlay/yolo11s.mlmodelc</string>
  <key>confidence</key><real>0.35</real>
</dict>
</plist>
EOF
killall -9 SpringBoard
```

---

## 7. 用了哪些私有 API

全部通过 `dlsym` 在运行时解析，**没有硬链接私有符号**（CI 里有断言守着这一点）。
符号不存在时是一条状态日志，不是 SpringBoard 崩溃。

| 符号 | 来源 | 用途 | 缺失时 |
|---|---|---|---|
| `CARenderServerRenderDisplay` | QuartzCore / CoreSurface | 把主屏合成进 IOSurface | 抓屏不可用，日志注明，只保留心跳 |
| `CVPixelBufferGetIOSurface` | CoreVideo | 取 pixel buffer 底层的 IOSurface | 同上 |
| `IOHIDEventCreateDigitizerEvent` | IOKit | 造 digitizer hand 事件（拖动容器） | 注入不可用 |
| `IOHIDEventCreateDigitizerFingerEvent` | IOKit | 造单指事件（位置 / 按下 / 抬起） | 注入不可用 |
| `IOHIDEventAppendEvent` | IOKit | 把手事件与指事件串起来 | 注入不可用 |
| `IOHIDEventSystemClientCreate` / `...WithType` | IOKit | 建 HID 事件客户端 | 注入不可用 |
| `IOHIDEventSystemClientDispatchEvent` | IOKit | 派发事件到系统输入流 | 注入不可用 |

公开框架：`Foundation` `UIKit` `Security` `CoreML` `CoreVideo` `CoreGraphics` `QuartzCore`。

IOHID 的常量（transducer 类型 2/3、event mask `0x03`）是编译期数字，无法运行时解析；
写错只会让事件变成 no-op，不会崩。

### 7.1 `CARenderServerRenderDisplay` 的版本适配

解析成功**不代表参数语义一致**。所以抓屏不是“假设一个调用形式”，而是按
（display id, surface 像素格式）跑一个固定的试探梯子，并记住成功的那一组：

| 顺序 | display | 像素格式 | 备注 |
|---|---|---|---|
| 1 | 0 | 32BGRA | iOS 15 及以前的常见形式 |
| 2 | 0 | 32ARGB | iOS 16+ 部分 10-bit 面板拒绝 BGRA |
| 3 | 1 | 32BGRA | 16+ 主屏索引变化的机型 |
| 4（仅 iOS 16+） | 1 | 32ARGB | 上面三项都失败时的最后一档 |

全失败时日志给出**逐项返回码 + 系统版本**，例如
`display0/BGRA:rc=-536870210 display0/ARGB:rc=... display1/BGRA:rc=...`，
`YOCapture.status` 里也是同一串 —— 这样“抓不到画面”能直接定位到是参数假设错了
还是缺 QuartzCore 权限。

### 7.2 最低系统版本（必须写）

dylib 用 `-mios-version-min=15.0` 编译。不写这一项，clang 会把 SDK 的默认最低版本
写进 `LC_BUILD_VERSION`，dyld 在 iOS 15/16/17 上**静默拒绝加载** ——
在设备上看起来就是“组件没装”。CI 里有 `vtool -show-build` 断言：

```
minos 15.0     sdk 18.5      (arm64 与 arm64e 两片都是)
```

`minos` 高于 15.0 直接 fail。

---

## 8. 已知限制（诚实清单，不是 bug）

1. **抓屏需要权限**。`CARenderServerRenderDisplay` 在部分系统 / 越狱环境下返回非 0
   （常见于注入方式拿不到 QuartzCore 相关权限）。日志会明确写出来。
2. **虚拟光标是估算的**。组件不知道用户手指此刻在屏幕哪里，只能从屏幕中心起算、
   跟踪自己注入的位移。要做到「相对真实触点」需要读 HID 事件流，本版没做。
   手感是连续小幅度拖动，不是从触点起算的绝对定位。
3. **注入是「按住 → 移动 → 松开」**（不是瞬移点击）：游戏里视角控制本来就是这个手势。
   每次注入是一次完整手势，频率限制在 20 Hz 且带 1.5 pt 死区。
4. **`aim` 默认关闭**。移动别人的手指不是合理默认值。
5. **窗口不可交互**（`isUserInteractionEnabled = NO`），永远不吃下层 App 的触摸。
6. **模型不会现场编译**：`.mlpackage` 必须先 `coremlcompiler compile`。
7. **合并进鉴权 dylib 的代价**：SpringBoard 里也会加载 `Security`/`CommonCrypto` 那套
   完整性代码（构造函数里只置一个标志，不做重活），对悬浮窗性能无影响。

---

## 9. 真机验证清单

Windows 上只能做静态检查和 CI 编译，以下每项必须上机确认：

| # | 项目 | 怎么算通过 |
|---|---|---|
| 1 | deb 安装 | `dpkg -i` 无错误，Sileo 里能看到包 |
| 2 | 注入成功 | `cc.ouovo.authcore.alive` 出现且时间在 5 秒内 |
| 3 | App Documents 里也有心跳 | 沙盒内那份时间戳同样新鲜 |
| 4 | 日志有 `starting in SpringBoard` | 构造函数进对了进程 |
| 5 | `overlay: window installed` | 窗口建起来了 |
| 6 | 悬浮窗浮在**别的 App** 之上 | 打开相册 / 游戏，框仍在 |
| 7 | 悬浮窗不挡触摸 | 悬浮窗区域能点到底层 App |
| 8 | 抓屏可用 | 日志 `capture: ... ready`，框跟着画面动 |
| 9 | 推理出框 | 含人的画面框住人，且随人移动 |
| 10 | 头部取点 | 准心落在框顶往下 22% 处，不是框中心 |
| 11 | 注入生效 | `aim:true` 时视角朝目标转动 |
| 12 | 注入不抢触摸 | 注入期间用户自己滑动仍正常 |
| 13 | 配置热更新 | 改 plist → post `cc.ouovo.yolooverlay.reload` → 3 秒内生效 |
| 14 | **不装 deb 的 App** | 真越狱机：启动约 10 秒后退出，日志有 `component missing` |
| 15 | **TrollStore 机不装 deb** | App 正常运行，不退出 |
| 16 | **未越狱机** | App 正常运行，不退出 |
| 17 | 卸载 | `dpkg -r cc.ouovo.authcore` 后 respring，悬浮窗消失、心跳停止 |
| 18 | arm64e 设备 | A12 及更新机型注入成功 |

---

## 10. 构建

macOS + Xcode，不需要 Theos、不需要 Docker、不需要 `dpkg-deb`：

```bash
# 1) 一个二进制（arm64 + arm64e）
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p authcore
xcrun --sdk iphoneos clang -arch arm64 -arch arm64e -isysroot "$SDK" \
  -miphoneos-version-min=15.0 -dynamiclib -fobjc-arc -O2 -fno-common \
  -I YOLOiOSApp \
  -install_name @rpath/AuthCore.dylib \
  -framework Foundation -framework UIKit -framework Security \
  -framework CoreML -framework CoreVideo -framework CoreGraphics -framework QuartzCore \
  -o authcore/AuthCore.dylib YOLOiOSApp/AuthCore.m YOLOiOSApp/OverlayEngine/*.m

# 2) 两个 deb
python3 YOLOiOSApp/OverlayEngine/make_deb.py --dylib authcore/AuthCore.dylib \
        --out authcore/debs --version 1.1.0
```

CI 里是同样两条命令（`Build AuthCore dylib` → `Build overlay deb`），
并断言：两个架构切片都在、12 个导出符号都在、每个引擎类都编进去了、
私有符号是 dlsym 而不是硬链接、产物是动态库、deb 的 ar 头正确。

`make_deb.py` 自己写 ar 归档（`!<arch>` + Python 生成的 60 字节成员头），
不走系统 `ar`：macOS 的 ar 和 GNU ar 对符号表的默认行为不一致，带 `__.SYMDEF`
成员的包 dpkg 会拒。脚本构建完会把包重新解一遍做校验（成员顺序、control 字段、
payload 里 `AuthCore.plist` 和 `usr/lib/AuthCore.dylib` 是否都在）。

---

## 11. 卸载

```bash
dpkg -r cc.ouovo.authcore
rm -f /var/mobile/Library/Preferences/cc.ouovo.authcore.*
rm -f /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.*
killall -9 SpringBoard
```

组件不写持久化 hook、不修改系统文件，删文件 + respring 就干净了。
注意：卸载后真越狱设备上 App 会在启动 10 秒后退出 —— 这是设计要求。
