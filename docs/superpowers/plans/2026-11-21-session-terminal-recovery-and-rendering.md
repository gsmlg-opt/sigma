# Session Web Terminal 修复计划

**目标**　在同一个 Sigma session 存活期间，关闭所有网页后，PTY 继续运行。新页面可以恢复原终端的屏幕、尺寸和近期历史；大段输出能及时显示。

**基线**　2026-11-21，Sigma main `d15a160`。实现沿用 `SessionSupervisor → Terminals.Subsystem → Manager / Worker → native helper`。Manager 管目录，Worker 管每一代运行的输出顺序、回放和连接，helper 持有 PTY 和 vt100 解析器，LiveView 与 xterm 投影状态。进程树和终端资源生命周期见 [终端 PRD](../../features/session-ui/terminals/prd.md)，消息约定见 [event contract](../../features/session-ui/terminals/event_contract.md)。

**执行结果**　Linux x86_64 上已完成五阶段验证，实测数据和端到端证据见 [终端验收报告](../../features/session-ui/terminals/acceptance-report.md)。

## 1. 优先修复 cat 输出逐帧显示

涉及 `apps/sigma_web/assets/js/hooks/session_terminals{,_test}.js`、`apps/sigma_web/lib/sigma_web/live/session_live.ex` 及对应 LiveView 测试。

- [x] 在当前 hook 测试里加入确定性用例：一次交付 120 个连续的单字节输出块，控制 xterm 完成回调与动画帧。当前代码每推进一次动画只提交下一块。修复后验证输出顺序完全相同，完成全部写入无需推进 120 次动画，累计 ACK 不能越过尚未解析的字节。
- [x] 对同一个 run 已到达的连续输出做有界批量写入。首块可立即提交，有积压时从队列取连续字节一起交给 xterm。以快照、尺寸变化、run 和连接恢复边界切分批次。渲染等待与下一批解析解耦。累计确认必须覆盖实际交付且已完成的连续序号，保留已有的去重、快照替换和旧回调失效规则。
- [x] LiveView 普通 ACK 仅更新当前 attachment 的已渲染序号。仅在恢复状态发生变化时更新前端显示与输入资格，由 catalog 变更通知处理目录刷新。保留对过期 ACK 的检查。验证一个慢窗口不会拖住另一个窗口。
- [x] 重跑相同 480 KiB、8,192 行的真实 PTY `cat` 和 120 个单字节块，在同一 Chromium 前台交替比较直接 xterm 和 hook，各测五次取中位数。记录字节数、帧数、解析完成时间、ACK 数和缓冲区结果。此前一次隔离测量中真实输出为 120 块，helper 用时 140 ms，直接 xterm 404 ms，旧 hook 2,039 ms；单字节场景分别为 5 ms 和 1,991 ms。结构性门槛是消除逐块等一帧，并验证最终屏幕、保留区内行号和顺序。计时另用完整 LiveView 链路复测。

## 2. 让服务端快照能重建原屏幕

涉及 `native/sigma_terminal_helper/src/main.rs`、`native/sigma_terminal_helper/tests/native.rs`。

- [x] 建立双解析器对照。一端连续处理原始字节，另一端读取快照后继续处理相同后缀。依次在 UTF-8 的每个字节边界、普通 CSI、进入或退出备用屏幕序列，以及 resize 前后截取快照。比较屏幕文本、光标、属性、尺寸和返回主屏后的历史。已有反例是切开 `€` 后字符消失，切开 `ESC[31mRED` 后显示为 `mRED`。
- [x] 让 checkpoint 的序号、可序列化的屏幕状态和待解析字节对应同一边界。使用可证明的完整解析边界加后续原始字节；尾部计入已有容量限制。部分 UTF-8、CSI 和控制字符串跨 PTY 读边界时也要成立。超限继续返回明确的快照失败。验证重复取快照不会改变正在运行的解析器或向 PTY 写入数据。

## 3. 修复超过 1 MiB 后的重新连接

涉及 `apps/sigma_agent/lib/sigma_agent/terminals/{screen_stream,replay,worker,attachment}.ex`、`apps/sigma_coding/lib/sigma_coding/terminal/native.ex` 和 native helper 的输出、退出协议。回归放在 `apps/sigma_agent/test/sigma_agent/terminals/{stream_control,native_stream_integration}_test.exs`。

- [x] 先用默认限制连续写入 17 个 65,536 字节块，期间无浏览器。复现从序号 0 attach 得到 `snapshot_unavailable`。保留纯 Replay 对「确实没有快照」的错误测试，新增正常 Worker 与真实 helper 自动恢复的用例。
- [x] Worker 在历史即将淘汰时请求 checkpoint。仍在运行的终端遇到回放缺口时也可按需请求。合并同一 run 的并发请求，以请求 ID、代号和输出序号关联结果。等待期间继续接受输出，使用有界缓冲；收到快照后只交付快照及其边界之后的连续事件。覆盖取快照过程中再次裁剪、两个窗口同时 attach、迟到响应和请求失败。不能以重新创建 shell 来完成恢复。
- [x] 自然退出时，helper 在读完剩余 PTY 输出后、失去解析器之前交付最终快照及序号。Worker 保留快照、退出码和已确认的清理状态。快照失败与进程清理结果分别记录。验收活跃和已退出两种终端，恢复后对照屏幕、最终标记、run generation；活跃用例同时核对 shell PID。

## 4. 使设备应答独立于网页连接

涉及 native helper、`screen_stream.ex`、`worker.ex` 和 `session_terminals.js`。使用真实 PTY 和安装的 xterm 验证。

- [x] 写一个 raw-mode PTY 程序，分别发出状态查询 `CSI 5 n`、光标查询 `CSI 6 n` 和主设备属性查询 `CSI c`，记录应答字节。用零窗口、单控制窗口、控制窗口加观察窗口重复试验。每种支持的查询恰有一次应答，光标与服务端屏幕一致。
- [x] 在服务端解析实时输出时生成应答，统一现有 `5n` 处理与 native parser 所见的状态。浏览器端使用 xterm 的解析接口消费已由服务端处理的查询，保留键盘、鼠标、粘贴和输入法事件。避免按字节内容过滤 `onData`，用户有可能真的输入相同字节。重新打开和回放同一查询时验证 PTY 收到零条额外应答。

## 5. 恢复视图、空闲控制权和长粘贴

涉及 `apps/sigma_web/lib/sigma_web/live/session_live.ex`、`apps/sigma_web/lib/sigma_web/session/terminal_binding.ex`、终端组件、hook 与对应测试。

- [x] 保留服务器作为「哪些终端已打开」的权威来源，沿用 PRD 的窗口级显示偏好。记录本窗口面板展开和选中项。刷新后等待服务端目录就绪，再恢复可用的选中项。恢复走只连接已有终端的入口；目录为空或 session incarnation 已改变时，不触发 `ensure_initial`。已有明确的开终端按钮继续遵循 UI-01。
- [x] 区分用户主动打开或切回终端与后台恢复。主动操作可通过现有 `acquire_control` 获取空闲控制权，已有控制者时显示只读及显式接管按钮。刷新与重连只观察，不抢占控制。用两个窗口验证同一 run、独立展开与选择、折叠释放、空闲重获以及接管后旧输入失效。
- [x] 补上同次 review 发现的长粘贴问题。按编码后的字节数切分，遵守当前默认 16 KiB 输入帧上限，顺序交给同一控制连接。用混合中英文和括号粘贴模式比较 PTY 收到的完整字节。断线或失去控制时停止剩余发送，重连不重发。

## 集成验收与执行顺序

先交付第 1 项的功能与性能验证。第 2 项验证快照正确性后再接第 3 项；第 4 项复用已验证的服务端解析状态。第 5 项接入恢复后的 attach 流程。功能检查在当前 checkout 内串行使用 Mix 构建状态：

```sh
(cd apps/sigma_web/assets/js/hooks && bun test ./session_terminals_test.js)
cargo test --manifest-path native/sigma_terminal_helper/Cargo.toml --test native checkpoint
./scripts/build-terminal-helper.sh
devenv shell --no-tui -- mix test apps/sigma_agent/test/sigma_agent/terminals/stream_control_test.exs apps/sigma_agent/test/sigma_agent/terminals/native_stream_integration_test.exs
devenv shell --no-tui -- mix compile --warnings-as-errors
devenv shell --no-tui -- mix format --check-formatted
```

对新增的 native 和 LiveView 用例按测试名或实际行号单独执行。最终使用独立测试 session 和已核实加载新 JS、BEAM 与 helper 的 Chromium 页面完成一条连续路径：打开终端并记下 PID → 关闭所有页面 → 后台输出超过 1 MiB → 新页面恢复同一运行 → 打开第二个窗口验证设备应答与控制 → 再次输出并自然退出 → 刷新读取最终画面及退出码。保存实测耗时和屏幕对照结果，再更新终端 acceptance report。
