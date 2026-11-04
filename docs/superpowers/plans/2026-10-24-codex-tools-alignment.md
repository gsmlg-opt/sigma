# Sigma 剩余 Codex tools 对齐

用户已授权在 `main` 继续实现，不创建 worktree。当前工作未提交；不包含自动
commit、push、发布、部署或替换正在使用的会话。本文是持久 Goal 的执行清单，
不是全量完成声明。具体架构与证据见 [协议说明](../../contracts/codex-tools.md)。

本阶段允许范围内的工具接入与剩余生命周期验收已完成；保留明确的TODO、适用平台和
历史事实边界，不声明全量Codex／全平台／完整Writer在线兼容。正式 **Backplane 1.10.53**
（source `012b7a750dcee5cfa48118d9c3eb87e03e411e22`）已采用；成功发布
[40981188107](https://github.com/gsmlg-opt/backplane/actions/runs/40981188107)解除#148，
#147原立即Stop完整回归通过，未等待allocation／ACK、未加本地proof或依赖补丁。
当前源码九文件48项；最终独立解压包tool48＋Operations4＋Web3共55项全过，
新BEAM冷读7 Store／12 run／7 journal、5 clock／2 Deno proof，53文件内容及metadata不变。
实际Protocol／Chrome完成原取消续接、准确dump、停止态无重放冷恢复及活动turn重载。
同一1.10.53包另完成完整42工具与三独立BEAM执行／冷读／显式续接；
此前1.10.51部分真实在线、1.10.52 Events／Goal等证据保留原版本。
完整Writer目录仍有encrypted History服务兼容边界，属于用户暂缓的remote History事项。
默认42工具、无Writer19、配置MCP与可选Plugins／V2集合均未为在线服务删改。

当前执行约定：默认使用 YOLO 自动批准，沿用 `default: allow`、空 rules 的现有
策略；Web／Protocol 加载该策略，managed child 继承根策略。按用户最新要求，不做
任何安全和权限相关开发或测试；下文已有相关实现与验收仅保留为历史证据，后续只做
允许范围内的功能验证、编译、格式与 diff 检查。

2026-10-27用户明确暂缓`web::run`、`image_gen::imagegen`及实际插件registry来源的
选择与接入：“这些作为todo就可以了，现在用不到”。同日又确认remote encrypted History
和`notes.thread_hint`“同样先记 TODO”。五项保留TODO，不作为本阶段完成条件；现有
本地History4／Notes5、configured插件宿主与剩余功能／生命周期验收继续，不选择默认服务或endpoint。

对照基线为 Runtime 固定的 Codex revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`；更新 builder 的差异另行标识。
每项只有实际宿主、catalog/authority、结果/历史和失败/取消/生命周期均有证据
才算接入。外部能力按真实配置暴露，不能通过空成功结果或工具名字凑齐。

## 1.10.53采用、恢复修正与最终验收（2026-10-30）

四个manifest最低版本改为~>1.10.53，mix.lock相对1.10.52仅五个Backplane条目变化；
HTTP0.21.17、ex_json_pointer0.8.0、plug_crypto2.2.0不变。公开locked resolution通过。
#147已正式发布，Runtime在executor／tool_started前登记clock ownership；现有
LifetimeEvidence和ToolPostHooks已透明保全权威证明／callback，无本地cancel实现。
原backplane_native_production_test.exs:358的时序和完整续接断言保持，仅移除已解决TODO；
seed43221一项通过／20排除。其旧teardown unconfirmed诊断不单独作为完整退休证明。

新增backplane_clock_wait_functional_test.exs立即取消PostToolUse案例：收到公开
工具开始事件便Stop，不等allocation／ACK；验证原Store intent与独立host binding的
精确proof、旧Session DOWN／新资源、下一真实Provider、新工作、旧效果和完整confirmed
退休。原四条root／child × direct／真实Deno案例不变。九文件48项通过（seed43227）。

实际Protocol验收暴露取消诊断tuple无法Jason编码：Operations.dump仅在diagnostics
递归转换tuple为JSON array，保留所有修复事实、未知entry、Unicode／CRLF及源文件。
operations_test.exs先red（seed43229，1失败／3排除），后4项通过（seed43230）。
冷恢复后新active turn丢失旧取消卡的问题由SessionLive复用现有selected-branch
cancelled_display_messages修正；不改Provider context或journal事实。
新LiveView回归先行为red（seed43233，1失败／2排除），后3项通过（seed43234），
覆盖compaction、闲置展示、新实际prompt、active mount／reload和源文件不写入。

最终完整prod包正常组装、tar后移走assembly并独立解压，565产品BEAM code identity与
实际路径匹配。原11文件快照／assertions不变；tool48＋Operations4＋Web3共55项全过，
零failure／exclude／skip（seed43237）。前两次包内harness分别漏mock_provider_module、
漏post-run inventory helper；失败日志保留，未改测试断言，最终完整通过。
另一个全新包BEAM只读此次7 Store／12 terminal run与7份journal；公开ToolEffects
用原operation及独立ledger复验5 clock／2 Deno outer proof，53原文件bytes／hash／
ns mtime／inode全不变，不启动Agent／Provider／旧效果。原detached-helper负向用例
仍如实unconfirmed，实际helper已退出。dev／test／prod warnings-as-errors通过。
证据`/tmp/sigma-clock53-e742ylg6/complete/{package/archive.json,accepted/}`；
最终archive SHA256为`53f5676acad3febab0723a0a16ff2f66a8534a890a787680a985f33334fc0a19`。

实际解压包Protocol与Chrome各5次受控Provider请求、3项成功结果：raw patch、clock等待
立即Stop、新clock及真实Deno／命令读回。Protocol在clock tool.started handler立即cancel，
Chrome实际点击Stop；旧Session DOWN、新Session／resources、原Store及公开proof和
confirmed durable host退休均核对。首个目录预检误把42 native＋6 V2当42总数，未发工具即
失败；新独立session完成，失败保留。原Protocol脚本结束时遇到上述dump编码bug，后续
修正包对原两个session成功dump及cold resume，不把原脚本报告改成通过。

新最终包BEAM让原两个session各Protocol resume两次并显式Chrome reload；完整dump
与baseline精确相同，保留原取消call和diagnostic数组。正确冷基线的27份session／effect／
log文件bytes／hash／ns mtime／inode全不变，Provider11／hooks10保持；11包含旧预检。
先前cold harness重读已消费control.json，显式retire了一个新空宿主，改写一份ledger；
其他26文件和全部原效果不变。原失败比较保留，启动时记录existing control bytes后重新
建post-retirement基线；不把夹具明确关闭说成自动恢复写入，也不声称旧ledger bytes未变。

Chrome再显式发新prompt，在实际Provider等待中reload：原取消clock卡、三项成功结果和
新active行保持，Provider input无原unresolved调用；释放后正常完成。该新工作是独立
写入边界：Provider最后13／hooks10；新增两次中一次为夹具错误处理binary content失败，
修正fixture后一次全新prompt通过，均保留。原Store／proof、三个journal字节前缀、hook
日志和patch效果不变；新宿主confirmed retire。最后没有重放旧prompt／effect。
served JS与包匹配；favicon404和主动停机connection-refused保留。自有42811服务、
BEAM／helpers／page2均已关闭，用户page1保留；4580无listener且未启动／重启。
证据`/tmp/sigma-clock53-e742ylg6/client/`，尤其`corrected-read-acceptance.json`、
`comparison-after.json`、`active-display-verified.json`、`active-final-acceptance.json`。

同一最终1.10.53解压包现逐项执行完整42项默认native工具，包含真实MCP资源／deferred
discovery、六项V2、managed-child真实Deno／followup与独立中断、跨turn PTY／cell、
Goal及hooks。原51夹具的action sequence与assertions保持，只机械替换版本与临时fixture
身份；各Store／Memory／repo均独立。三个不同包内BEAM均核对五包版本及19核心模块路径。
第二BEAM不启动Agent，冷读122条canonical消息、全部42项工具结果、原图片bytes／detail
和两张async卡片；27份durable／effect文件bytes／hash／ns mtime／inode全保持，
Provider67／MCP事件12／hooks55不增加。第三BEAM接受显式新prompt，读原Notes／Memory／
reset前History／Board／completed Goal，续接原已完成child执行真实Deno／MCP，Provider
新增12至79；原journal前缀及patch bytes／mtime保持，完整退休confirmed。
三个BEAM和两个自有MCP进程均已退出，4580不启动／重启。这是Linux x86_64/Nix的controlled
Provider生产包功能验收，不扩展真实在线范围。证据`/tmp/sigma-full53-21bk2iaf/acceptance.json`。
本轮无产品源码／测试／依赖变更，仅同步四份工程文档；保留所有既有工作。

Canonical Agent Note `5e9ffc9a-fbb2-49d4-942d-d935f4d4ef56`已整合至revision102并
精确get回读；2373字符旧工具移除清单、其他工具表格和title／project labels／attachments保留。

历史#148证据：Release40912562108的Memory V2 fresh-schema chain于60000ms超时，
只确立当时观察，不推断根因；未重跑上游workflow／tests。旧52立即Stop和公开三窗口探针
失败均保留；现以官方53采用和原完整回归解除，不以issue closure代替消费者验证。

## 1.10.52独立解压包验收（2026-10-30）

标准prod Mix release成功组装、tar后移走assembly，再独立解压。六个Sigma和五个Backplane
应用共565个产品BEAM的公开code identity与当前prod一致，实际加载路径全部来自解压包。
同九文件原断言及Events fixture逐字快照/hash一致，47项全部通过、无exclude／skip
（seed43225）。这是源码47项的独立包内复验，不累计为94个不同功能。

另一个全新包BEAM冷读这次测试新产生的6个Store／10个terminal run和6份journal；
公开ToolEffects对4份clock与2份Deno外层proof，按原Store operation及独立binding ledger
重新验证。44份文件bytes／hash／ns mtime／inode全部不变，不resume Agent／Provider／旧效果。
两个BEAM PID不同且均已退出。hook关闭未确认日志对应原有detached-helper负向用例，
保留实际unconfirmed；精确helper已退出，不能据此重写旧退休结果。

首次构建别名碰到独立旧sigma_rel缓存（Backplane1.10.15），未清理该缓存；
前置assets／native／guardian构建已成功，标准Mix release随后使用已核实1.10.52的
正常prod目录完成组装及依赖检查，不跳过检查，不改构建代码、锁或依赖。
构建后675份源码全部不变；本轮写入仅限最终工程说明。未运行安全／权限／沙箱测试。
证据：`/tmp/sigma-packaged52-h_29umea/{acceptance.json,beam-code-identity.json,
runner-packaged-functional-acceptance.json,packaged-cold-read.json,clock-file-comparison.json}`
与`package/archive.json`。4580无listener，未启动或重启该服务。

同包另完成实际Protocol／Chrome：独立repo／session各9次受控Provider请求与6份成功结果，
真实automatic hook veto后保持原host-effect settlement与同一Goal，普通Events／真实Deno
MRTR／原生错误catch后继续，再由新自动工作完成Goal。公开thread_id匹配dump.header，
durable Goal ID另行核对；两根宿主均返回confirmed durable retirement。

完整旧BEAM退出后，独立新包BEAM让两个原会话各经Protocol resume两次，并显式浏览器
reload；完整canonical dump相同，6张成功卡／3段完成文字保留。恢复／reload期间27份
会话文件与Provider／hook两份日志bytes／hash／ns mtime／inode全不变，Provider18／hooks25／
Events10次数不变；MCP仅新增6条发现／订阅／工具列表读取。最终有序关闭是另一写入边界：
两份host-retirement ledger写入新空宿主的实际关闭事实，均无native binding；另外27文件
仍精确相同。不可把恢复阶段的29文件不变扩展为最终关闭后所有ledger不变。

Chrome保持connected、无横向溢出，served JS与包字节匹配；两个favicon URL为404，
主动关闭期间另有预期connection-refused。首个缺Deno的启动预检失败保留；修正devenv
环境后用新Protocol会话，harness的字段断言仅针对原dump／facts离线修正，无prompt重放。
自有服务／fixture／tab均已关闭，4580仍无listener。
证据`/tmp/sigma-packaged52-h_29umea/client/{client-acceptance.json,
protocol-initial-acceptance.json,cold-read-acceptance.json,resume-comparison-command.json,
file-comparison.json,final-retirement-inspection.json,final-stop.json}`及`client/browser/`。

该历史批次没有1.10.52在线模型新验收，当时完整42工具与真实在线结果均为1.10.51。
当前完整42项生产包验收已提升至1.10.53，真实在线仍保持原1.10.51范围。
其revision100 Agent Note与注册后47项验收当时不覆盖#147；当前1.10.53原完整立即Stop
及恢复修正的采用／消费者证据见文首，原2373字符旧工具移除清单继续保留。

## 1.10.52源码验收（2026-10-29）

1.10.52采用：四个直接依赖最低版本同步更新，mix.lock相对1.10.51只改五个Backplane
entries；HTTP0.21.17、ex_json_pointer0.8.0及plug_crypto2.2.0不变，locked resolution通过。
LifetimeEvidence新增识别公开native_clock_wait_retirement，原样保全权威Store记录；
Runtime负责真实waiter／executor join、timer退役、completion gate与nested Code Mode关联。
没有增加本地parser／executor，ToolPostHooks保留原callback且无需改动。

新增四项真实Engine功能覆盖root／managed child × direct／真实Deno、PostToolUse、
精确registration／generation／Session／invocation proof、下一真实Provider／同child followup、
旧Session DOWN／新资源、旧Store与journal前缀／patch效果／hook次数不变及完整host退休。
初次seed43222已过证明与续接、但四项均因测试误读Provider投影map的metadata失败；
仅改为解码实际model-visible JSON文本，产品代码不变。四项seed43223通过，
合并原八文件后47项seed43224全部通过，不把重叠选择累计为独立总数。

独立新BEAM再冷读原6个Store／10个terminal run；公开ToolEffects验证4份clock与2份
Deno外层proof，operation来自原Store，Session identity来自独立host binding ledger，
nested identity／digest保持精确。6份原journal可读，44份fixture／effect文件bytes／hash／
ns mtime／inode全不变，只启动Store／Log reader，不resume Agent／Provider或旧效果。
证据`/tmp/sigma-clock-cold52-ibxz151l/{cold-read-result.json,file-comparison.json}`。
这是1.10.52当前源码冷读验收，不扩展为安装包／真实客户端新工作恢复。

原立即取消回归在仅升级包与增加proof collector后均失败（seed43220／43221，各1失败／20排除），
原next-Provider／Session-DOWN／新资源断言完全保留。Store副本public load显示uncertain原调用、
unknown_outcome及generic worker-stopped cleanup，没有typed clock proof。独立纯Backplane
公开API探针实际执行三个时点：tool_started立即取消、真实allocation后／registration ACK前取消
均无证明；调用原callback得到真实ACK后取消则有native_clock_wait_retirement。
这解释了#146已发布但原复现仍不通过；剩余#147是blocker，不用allocation-gated成功替代它。
探针只读公开Registry实际分配，不访问Runtime私有状态、不伪造callback或proof。
证据`/tmp/sigma-clock-adoption52-5bdzn1hl/{original-clock-green.log,initial-clock-evidence.log,
clock-four-paths-rerun.log,integrated52-functional.log,public-clock-startup-probe.exs,
public-clock-startup-probe.log}`；原green命名的日志实际仍失败，不能误报。

dev／test／prod warnings-as-errors与显式format／diff检查通过；三份编译inventory中的
五个Backplane版本均为1.10.52。674份原源码基线仅11个授权既有文件变化、新增1个功能
测试文件，其余663份保持、无删除。本轮没有启动或重启服务；收尾只读检查4580无listener、
旧PID815717也已不存在，不据历史“服务未变”描述推断当前仍在运行，未擅自启动。

同一canonical Agent Note `5e9ffc9a-fbb2-49d4-942d-d935f4d4ef56`已更新并精确回读
revision95；2373字符旧工具移除清单及title／project labels／attachments保持。
原有1.10.51安装包／客户端／在线范围保留，正文整合1.10.52公开clock机制、四条实际续接、
47项合并功能、独立BEAM原proof／journal无写入冷读与#147可运行启动窗口复现。

以下真实Provider／安装包／客户端结果属于此前1.10.51批次：

用户已选择 `prov_3592 / gpt-6.1-sol`。第一次真实完整目录请求以HTTP400失败，
原Store冷读确认缺少`tools[7].description`；临时验收脚本随后将Message struct直接编码的
错误曾遮住原错误，已改为先落盘真实turn结果并投影可编码数据，不改产品Message encoder。
Sigma Responses namespace projection补必需的非空description；原custom／namespace wire回归
先失败后通过（seed43210／43211，后者1通过／36排除），原raw／schema／call身份断言保留。
dev／test／prod warnings-as-errors及两文件format通过；五包／lock与生产inventory均未改。
新生产包独立tar解压、移走assembly，四个实际模块的公开BEAM code identity与当前prod一致。

修正后的完整Writer目录仍被所选服务拒绝：HTTP400 `invalid_request_error`，要求
`history.search_contents.query`声明`encrypted: true`。这是当前在线服务与本地明文History
的兼容边界；用户已暂缓remote encrypted History，本轮不实现或伪标加密、不删改生产工具或
更换Provider默认值。两次原失败记录保留，完整默认目录在线验收尚未通过。

独立使用既有无Writer profile（native19＋实际MCP4／discovery1）验证不依赖History的链路：
6个真实turn／19次Provider request与response、38条canonical消息、13个outer工具结果全部成功，
请求与响应model均为gpt-6.1-sol。实际clock、Plan、raw apply_patch、Unicode文件创建／命令读回、
3个真实Deno cells、原detail图像完整回传（模型正确识别左红右蓝）、tool_search→直接MCP及
后续turn search→Deno MCP均通过；服务收到精确LF／CRLF／首尾空格，null／boolean结果保留。
Plan在后续turn保持completed。无Writer的实际退役返回capture:disabled／confirmed，owned
BEAM及stdio退出；新的独立BEAM仅通过public Store加载6个completed run，effects／outbox为空，
12份文件bytes／ns mtime／inode全部不变，Provider／MCP不增。不推导为Writer／managed-child
在线恢复或默认42项全量在线验收。初次空启动误复制stop控制文件，没有Provider请求；包初始
raw-BEAM比较因release stripping不同，改用公开beam_lib code identity而非更改源码或模块。
证据/tmp/sigma-live-provider51-nk_kvunj/{failure-store-read.txt,local-source-delta.patch,package,
attempt2/probe.json,writerless/online-acceptance.json,writerless/cold-read-acceptance.json}。
全局五份配置的bytes／mtime／inode保持，原4580未重启，无commit／push／发布／部署。
674份源码基线仅上述adapter／既有回归及四份对齐文档共6份变化，其余668份保持。
同一canonical Agent Note已更新并精确回读revision92；原2373字符旧工具移除清单、
title／project labels／attachments不变。该批次Goal保持blocked；随后1.10.52曾恢复active并完成注册后路径及冷读；最新Goal状态与正式发布阻塞见文首。

最新root-production审计修正两项目录测试：显式固定42项，补入已经接入的环境等待、Goal3、
Board9，仍严格比较完整集合；手工无client的MCP fixture保持既有eager契约。
stopped hook按公开presentation／feedback分离，严格验证原stopReason、additionalContext、
同call ID下一turn及一次实际Plan／hook／JSONL。owner／Plan故障的实际命令和进程清理原断言
保留；宿主预检查在进入Engine前拒绝工作，改校验精确pending turn的turn_failed，并新增原工具
结果不变断言。最初14项13通过／1失败（seed43200），两项owner-loss经旧终态断言和turn ID
响应shape修正后通过；最终16项联合15通过／1失败／5排除（seed43204），未运行其他混合用例。
失败为取消clock::sleep后新prompt的Provider不可达，后续旧Session DOWN／新资源断言仍保留。
实际Store的副本经public load／run_obligations冷读确认unknown_outcome、uncertain原invocation、
cleanup_required.tools和公开tool义务；effects／outbox虽空，不证明退休。已提交并精确回读
Bug／internal request backplane#146；无本地proof、清义务、依赖补丁或效果重放。child／真实Deno
clock取消未复现，不推导为通过或失败。证据/tmp/sigma-catalog-audit51-pfqwbnaz。
该源码审计时尚未选择线上Provider；本轮用户选择及独立部分在线验收见上文，
既有本机受控Provider证据保持原适用范围。
dev／test严格编译、显式格式与diff检查通过；674文件基线中仅该测试及四份对齐文档变化，
其余669份保持，无删除。canonical Agent Note已精确回读revision90，2373字符旧工具删除清单及
title／project标签／attachments不变。随后连续阻塞审计已将Goal设blocked；
未重启4580或执行Git发布操作。

最新恢复修正：SkillInvocationStore.recover只在preparing／queued／running实际变为interrupted时
写入；缺失ledger保持不存在，空／terminal ledger保留原始JSON bytes与文件identity，二次恢复只读。
三项新功能回归先复现旧写入；修正后与原store三项联合6通过（seed43190），既有direct Protocol／
WebSocket resume各按精确位置独立通过。最初并行暴露全局ETS表owner退出竞态后，第四项公开API／
FIFO回归确定性复现：一个已完成caller退出，另一session读完后在ets.delete崩溃。
现改为本节点per-session :global.trans，删除caller-owned表／polling；保留atomic writer和互斥，
新文件恢复async:true。源码7项并行通过（seed43194），direct Protocol／WebSocket精确resume
各通过（seed43195／43196）。最初串行6项是历史结果。ledger-only新包独立tar解压／移走assembly，
确认实际模块路径与当前prod BEAM code identity。两个原session各自真实Protocol resume两次、
Chrome载入／reload后，23份持久文件bytes／hash／ns mtime／inode全不变；原本不存在的
browser skill ledger仍不存在，完整六份结果及原Goal settlement保持，Provider／hooks／Events不增。
MCP重连只有两组discover／subscription／tools-list，served JS匹配包，connected且无overflow／
console warning/error。自有服务／fixture／页关闭，4580未动；dev/test/prod严格编译、显式格式／
diff通过。首次误选旧release build cache在版本检查处停止，改用已核实的当前prod cache后编译／
组装成功；无依赖／lock修改。证据/tmp/sigma-skill-recovery-4kpxqdhj/client-acceptance.json。
下述1.10.51初次客户端的22／23 metadata结果保留为修正前历史。

锁修正另组装package-lock归档并独立解压／移走assembly，公开BEAM code identity及模块路径与
当前prod一致；原7项assertion在包内BEAM以32-case并行配置全部通过（seed43197）。独立包BEAM
重复恢复两个原Protocol session，各保留六份完整结果、原Goal及settlement；23份durable文件加
Provider／hook日志bytes／hash／ns mtime／inode全不变，缺失ledger仍不存在，执行不增；MCP只加
两组discover／subscription／tools-list。Chrome未因纯锁变更重跑，沿用上段ledger-only包独立结果。
自有包服务／HTTP fixture均join退出，4580未动。首次FIFO使用普通File.open受file-server阻塞，
仅停止自有测试BEAM；raw配对后成功复现真实故障。首次client dump命中旧测试文件already_exists，
保留旧dump并改唯一输出路径后通过，未改产品逻辑。证据/tmp/sigma-skill-recovery-4kpxqdhj/
package-lock/{archive,packaged-contract-acceptance,client-acceptance}.json及lock-{red-raw,green}.log。
同一canonical Agent Note（5e9ffc9a-fbb2-49d4-942d-d935f4d4ef56）已更新并精确回读revision89；
原2373字旧工具删除清单、title／labels／attachments保持，只整合当前恢复机制及版本化验证边界。

此前1.10.51批次锁定五个正式Hex包（source `389b0956a2cce9a51c1782327a806b299f94c5a5`）。
相对1.10.50只改五个Backplane lock entries；HTTP 0.21.17、ex_json_pointer 0.8.0及plug_crypto 2.2.0保持。
MCP Events采用public event_request／start_list_events，原始单页、opaque cursor、MRTR、
RPC／domain错误、root取消／child中断后同client／同child续用与完整退休通过；
直接结果保留完整错误details，真实Deno按native契约catch原message后在同JS继续，Store保留完整错误。
#145原完整hook-veto回归现通过；Session／Goal准备前保持实际hook ownership，
真实index I/O故障在Session确认关闭后结算，准备期间取消阻止binding；成功index后的不确定
handoff仍保留普通indexed恢复。最终八文件43项功能检查全通过（seed43186）。
证据/tmp/sigma-alignment51-o9l_8mm3/integrated51-functional.log；不与重叠范围累加。

1.10.51生产包独立tar解压后移走assembly，确认五包版本与实际包内模块路径；
包内重复八文件43项功能检查全通过（seed43188）。全部42项默认工具、实际MCP／discovery／
六项V2协作、same-child真实Deno／followup／独立中断、跨turn PTY／cells与完整退休通过。
三个独立BEAM覆盖执行、停止态122条canonical／完整图片／两张async卡片冷读、显式新prompt
续接原已完成child再完整退休；27份文件bytes／SHA256／ns mtime／inode不变，
Provider67／MCP事件12／hooks55不增加。新工作Provider增至79，原journal前缀和patch效果保持。
证据/tmp/sigma-alignment51-o9l_8mm3/package/{archive,packaged-contract-acceptance,first-acceptance,cold-read-unchanged,resume-acceptance}.json。

同一1.10.51解压包的真实Protocol／Chrome各自create Goal、实际自动hook veto、普通prompt与
同Goal新自动工作完成；原Goal ID及host-effect settlement完全保持。direct Events、真实Deno
MRTR、catch原native RPC message后同JS新Events均保留完整原页。两个host完整退休confirmed。
旧BEAM退出／新PID后Protocol停止态resume、Chrome显式reload保留各六份完整结果，
23份持久文件contents相同、22份ns mtime／inode也不变；一份原有空skill侧文件重写`[]`。
Provider／hooks／Events执行不增加；MCP重连仅新增两组discover／subscription／tools-list读取。
两个成功选中session共18次Provider；全局日志另保留9次早期fixture准备调用，不计成功数量。
connected、无overflow／console warn／error，served JS与包内字节一致；自有服务／fixture／页已关闭，
原4580未动。证据/tmp/sigma-alignment51-o9l_8mm3/client/final-client-acceptance.json。
本地受控Provider／HTTP fixture验收与在线模型、其他平台、远端CI、发布、部署分开。

Canonical Agent Note `5e9ffc9a-fbb2-49d4-942d-d935f4d4ef56`已更新至revision87并精确回读。
原2373字符旧工具移除清单、title／project标签／attachments保持；同一工程说明整合1.10.51
Events、Goal host-effect结算／准备handoff、包内43项、默认42项／三BEAM和实际客户端证据，
并保留未完成边界及用户五项TODO。669文件基线仅19个授权既有文件变化、新增4文件，其余650份保持。

下述1.10.50源码、客户端与生产包证据保留原版本，不作为1.10.51客户端／包验收：
此前五个正式Hex包升级1.10.50（source `a81325c3502be53bba5465145c4bca2dedd9eb98`）。
相对1.10.49只改五个Backplane lock entries；HTTP 0.21.17、ex_json_pointer 0.8.0及plug_crypto 2.2.0保持。
#141公开resource_scope_retirement已由LifetimeEvidence原样保全，交公开reconciler校验；
#142公开register_code_mode在execute／resume前注册真实worker，原ToolPostHooks已保留callback。
原两项MCP最终退休与四项root插件取消（direct／真实Deno，各有／无PostToolUse）全部通过，
没有修改原断言、移除hooks或添加本地取消／proof绕过。随后七文件88项功能检查通过；
两项旧child首次新增tool_search超原目录上限的案例按权限范围排除，原完整回归保留。
此前1.10.48的80通过／4失败与1.10.49对照保留历史范围，不与本轮重叠计数相加。

1.10.50独立Protocol真实Deno与Chrome Stop通过真实PostToolUse下的取消验收。
晚到的Protocol／Settings显式安装不改旧requests／两份journal／两份Runtime的bytes、ns mtime或inode；
下一真实prompt完成plugin MCP、完整Unicode／LF／CRLF skill，两个根完整退休confirmed。
旧BEAM退出、新BEAM停止态resume／installed重试及Chrome reload保持Provider12／HTTP4／hooks8，
MCP starts／calls均2不增加。32文件contents相同，31份metadata也不变；一个原有空skill-invocations
辅助文件重写`[]`，不宣称全部mtime／inode相同。connected、无overflow且served JS匹配本地产物。
自有服务／页面已关闭，原4580未动；这是本地受控Provider源码客户端验收，当前生产包独立验收见下文1.10.50。
证据/tmp/sigma-alignment50-em57u8o6/client/final-client-acceptance.json。

取消工具卡另修正为按原message的durable turn显示turn cancelled与中性pending；
多assistant行同步更新，已成功／失败结果不改，下一turn不复活旧running。
停止态reload只读取Writer选中branch中已展示的原取消assistant，Provider repaired context保持。
没有虚构工具结果、Runtime结算或journal写入。
8项Web定向功能检查通过（seed43165），含Writer真实checkout隔离与Provider context断言；
最终源码Chrome cold载入／reload保留无result的取消卡和4张成功卡，32文件bytes／ns mtime／inode
在显示验收期间不变，无console warn／error或overflow。有序host退出另写自己的退休事实。
dev／test／prod严格编译、assets build、显式格式与diff检查通过；669文件基线只改15个既有文件，
其余654不变，无新仓库文件。证据/tmp/sigma-alignment50-em57u8o6/client/ui-final-acceptance.json。

- [x] 1.10.50当前源码生产包独立tar解压：实际包内BEAM／terminal helper／MCP guardian，
  全部42个默认native工具、MCP三项资源／discovery／完整structured结果、六项V2协作、
  same-child真实Deno／followup／独立中断、跨turn PTY／cell和完整退休通过。
  三个独立包内BEAM分别执行、停止态冷读、新真实prompt续接原已完成child再完整退休；
  冷读122条canonical／图片与两张async卡片，27份文件bytes／SHA256／ns mtime／inode不变，
  Provider67／MCP事件12／hooks55不增加；新工作另加12次Provider，原journal前缀及patch不重放。
  原#141／#142六项完整回归在实际包内BEAM通过（seed43166），两份源测试文件字节相同；
  最初tag筛选错误运行了较宽范围并复现两个已排除child目录失败，独立保留该结果，
  修正后仅运行六项既定功能案例，不改生产代码／grants／原断言。
  包内插件guardian真实parent／exit0／确认cleanup、重复close无效果及当前JS hash通过；
  自有BEAM／工具进程均退出，原4580未动。本机受控Provider包验收不代表浏览器、
  在线模型、远端CI、其他平台或部署。证据/tmp/sigma-installed-native50-e0xmk4o3。
- [x] 2026-10-29只读核对Codex builder `c8bd6c1da9782bb92cf300a8768f87232b2d5631`
  （blob2602fcb9bbbd9f916444d0c338a161b9fa9b5413）：相对原9a8a85b比较版本，此文件
  未新增工具名／family；变化为显式dynamic_tools、MCP namespace默认description与model context
  descriptions。不代表全仓库无差异，Runtime执行inventory仍固定46fdd5e。
- [x] 历史1.10.49本机Linux x86_64/Nix完整生产包独立tar解压：42个默认native工具逐项真实执行，
  另加MCP资源／discovery／结构化结果与六项V2协作，实际child Deno／same-child followup／
  独立Provider-only中断、成功turn跨轮PTY／Deno与full retirement通过。
  三个独立installed BEAM覆盖停止态122条canonical历史／完整图片与两张async卡片冷读、
  新真实prompt读回旧状态及原已完成child Session的Deno／MCP续接，再full retirement。
  冷读28份文件bytes／SHA256／ns mtime／inode不变，Provider67／MCP事件12／hook55不变；
  新工作另增加12次Provider，原journal前缀及patch效果不变。原unknown usage继续明确不确定。
  包内插件guardian实际parent／exit0／确认cleanup及重复close无效果通过；自有BEAM／工具进程已退出。
  被中断child的原unknown_outcome不在公开archive eligibility；此前1.10.48失败探针保留为该明确边界，
  不用假archive或扩eligibility通过。仅本机受控Provider打包验收，不代表其他平台／在线模型／远端CI／部署。
  证据/tmp/sigma-installed-native49-yi4ktiel；原4580/PID815717未动，无安全／权限／沙箱开发测试。
- [x] 1.10.49四个manifest／五项lock限定升级、locked resolution、dev/test/prod严格编译、
  五个相关Elixir文件格式与diff检查通过；#140原断言先RED后GREEN。#141两项最终失败与#142
  一项完整失败保持；旧child新增discovery目录上限仍按此前范围保留，不扩权或更改准入策略。
- [x] 1.10.49独立4676真实客户端补验：Protocol真实Deno与Chrome Settings均等待显式安装，
  原public request ID／完整completed与user_confirmed／不可变invocation及实际settings／protocol
  确认来源一致；下一真实turn完整读取Unicode／LF／CRLF skill。页面reload、旧BEAM退出／
  新PID及Protocol resume／installed重试／浏览器reload后，九份持久文件bytes／SHA256／
  ns mtime／inode完全不变，Provider10／HTTP4不增加。三张成功卡、两条installed、connected、
  无overflow，served JS与本地产物一致。本次自动重连成功，停机期间预期连接拒绝保留；
  旧select_model loading竞态未复现、未修复。证据/tmp/sigma-plugin-client49-0a0m9b03；
  自有BEAM／registry／两页均已关闭，原4580/PID815717未动，无安全／权限／沙箱开发测试。

- [x] #134公开staged export：实际关闭前保存所有eligible未归档child的stage，原Goal失败／
  pending字节保持；冷启动真实计费／ACK及receipt刷新后公开complete，再按原身份parent-first恢复。
  队列中的stage与已完成未消费的retirement Task关闭竞态、nested、独立BEAM和新工作通过。
  full close／文件操作／新准入仍须完整archive；没有stage的突退出或legacy缺事实仍拒绝。
- [x] #141公开typed scope proof已采用1.10.50；两项原最终retire_host断言通过。
- [x] #142原生PostToolUse与Deno取消组合已采用1.10.50公开worker注册；原proof、
  late install、下一prompt／MCP与full retirement全部通过，真实Protocol／Chrome另验收。
- [x] [#144](https://github.com/gsmlg-opt/backplane/issues/144) MCP Events：采用1.10.51
  公开caller-owned lifecycle；direct／真实Deno、精确MRTR取消、独立caller、同client／同child
  续用、完整RPC／domain错误details与无重放history共9项通过（seed43185），并纳入43项合并验证。
- [x] [#145](https://github.com/gsmlg-opt/backplane/issues/145) effectful pre-Runtime Goal结算：
  正式1.10.51 Goal.settle_host_admission/4保留原有序host results、terminal result、
  executor DOWN、实际command cleanup与future-start fence，Agent收到durable ACK后才发终态。
  Hook scope覆盖实际Session／Goal准备，只有明确失败且Session确认关闭才允许host结算；
  成功index后的handoff／startup不确定保持indexed恢复。原hook veto完整回归、真实index写故障、
  准备期间取消、顺序／并发workers、写失败仅重存及原Goal／instructions／full retirement通过。
  旧1.10.49／1.10.50失败为历史（goal-hook50-baseline.log，seed43171），不使用none_dispatched、
  Goal reset、伪Runtime receipt或本地依赖补丁。文首另有当前解压生产包及实际客户端独立证据。
- [ ] 旧child安装后新增discovery的followup契约：原ceiling无tool_search；保持明确错误，
  不用自动扩权或替换child身份完成验收。安全／权限开发测试继续排除。

## 已采用的上游能力

- [x] 1.10.44阶段将发布的五个 Backplane 协议包锁定到该版本（release
  `71f108ec58f562da7b0ba308f091871458a14010`）；另同步8个必需HTTP包至0.21.17，
  不含其他lock升级或依赖源码补丁，`deps.get --check-locked`通过。
  已消费#109终态Goal ACK、#110 active notice到期、#111普通nested Error、
  #112 Responses图片和#114 nested backend context；不是只更新版本号。
- [x] 按用户约定延后一小时，于2026-10-27 13:48（Asia/Shanghai，UTC05:48:14）核查：
  当时#122／#123／#124／#126／#127／#128均open，latest release和五个Hex包仍1.10.43。
- [x] 随后正式采用07:31:55 UTC发布的1.10.44 resource handles、plugin close/status与
  显式verified-completion契约。root资源取消与PluginRuntime原失败关闭回归通过；
  当时child资源中断仍unknown，公开API探针确认DynamicRuntime持有request而不跟随effect caller退出，
  已提交[#131](https://github.com/gsmlg-opt/backplane/issues/131)。archive元数据字段已放宽，
  但原生Error规范化仍失败，已补充消费者证据并重新打开#126。Goal记账后的真实
  rename／followup及独立两BEAM续接已通过；闲置imported child的parent transfer另受#133阻塞。
- [x] 采用包含 #86/#87/#88/#89 的正式发布包；公开 DynamicRuntime 验证 metadata
  命中与 caller/run/incarnation 独立 owner staging，公开 Conversation 验证相同
  async 问题的可信独立 call/invocation identity。child 与 publication 产品验收另列。
- [x] #85 精确 child interaction cancellation：完整 correlation fencing、一次提交、
  丢失确认不重试、已提交原生提问保留 unknown_outcome。
- [x] 根原生 profile 与 MCP/V2 collaboration 原子合并；复用长生命周期 Session
  资源，成功 turn 保留命令句柄，取消/失败关闭 generation。
- [x] 采用 1.10.37（release `9424dfd558f5c85f5036039f745bf7f8d8313e18`）中
  #90–#105 的正式修复；未接入的宿主仍保持未完成，不再标作等待上游发包。
- [x] `apply_patch` 恢复 root／managed child 的默认与显式准入，复用公开原生
  backend；raw add/update/move/delete、完整有序结果、真实 Deno、JSONL、根重建及
  child followup 无重放已有功能验收。不做本地parser／executor或权限/preflight开发。
  当前核心12项和本地environment1项，加Skills2／Memory4为19项；有Writer和transcript
  再加History4／Notes5／async2／Goal3／Board9为42项，MCP／配置后的Plugins2／V2协作另算。
- [x] 部分资源关闭可重试：分别保存公开 Session 和 Skills 的 confirmed cleanup，
  后续 child stop 失败仍关闭准入；进程退出后能完成close，不再次调用已死Session。
- [x] 根 Engine 接入 prepare/post hooks、同步问答与权限 responder；原始调用、
  结构化结果、checkpoint feedback 进入主历史，并可由 JSONL seed 新 run。
- [x] Web 与 Protocol 入口选择 native profile；已有 LiveView/Channel 集成验证
  同步提问、Plan 审批、晚答拒绝和 reload。早期 raw patch 的 #104/#105 阻塞保留为
  历史；当前已采用发布修复，root／child 的公开原生 patch 功能验收见上项。
- [x] 真实浏览器与独立协议连接验收；与受控 Provider/HTTP fixture 证据分开记录。

## 正在推进的宿主工作

- [x] 采用1.10.52／backplane#146公开clock wait退休契约；root／child × direct／真实Deno
  保留精确权威证明、下一真实工作、旧Session DOWN／新资源、历史／效果不重放及完整退休。
- [x] backplane#147：官方1.10.53已发布并采用，Runtime在tool_started前登记实际clock
  ownership；原立即Stop完整新Provider／旧Session DOWN／新资源回归及新增无allocation／
  ACK gate的PostToolUse案例通过，确认旧效果保持和完整退休，没有本地绕过。
- [x] 同步 PostToolUse 使用公开 `ToolEffects.present/3` 分离实际结算与呈现。
  stopped 包括显式空文本，替换模型输出、保留 nested 实际值；block 同时成为模型及 nested error。
  additionalContext 独立投递，已完成效果保持原结算，后续请求／JSONL／重建不重放。
  #107 已随1.10.38采用，移除旧空文本诊断旁路；四项空文本回归先在1.10.37失败，
  root／child × direct／真实Deno共12项呈现功能用例全部通过。
- [x] Async hook 基础：独立 `hook_feedback` 账本、Writer 文件同步与可信 session／
  所选 raw branch 校验、全局去重、原始 handler index／配置 digest 身份，分别保存
  canonical／实际 Runtime ID；重启不重投 unknown，回放损坏阻止写入。Runner 在
  排队前生成独立 callback，factory 拒绝时不执行 hook、不 fallback。
- [x] Native async hooks：root／child 的 owned Writer 直接收集原文，公开 Store
  核验精确 consumed intent 与成功结果；active steering／下一条通过真实
  UserPromptSubmit 的 prompt 接入。canonical 消息和实际 Runtime checkpoint
  共同证明消费，不捕获过期 producer callback，不用 idle steer 启动额外 turn。
  已覆盖取消、重建、identical handlers、真实 Deno、queued-only／wrong-ID／
  missing checkpoint／sibling negatives、root／child shutdown。child 的真实
  steering checkpoint 与多个 ready hooks 并发回归先失败再通过，投递 worker
  在 ChildIO 外运行，checkpoint 不等待 worker，轮询只保留单 token timer。
  consumed 回执写入失败的实际 Conversation 回归也先失败再通过：当前 checkpoint
  立即返回 projection failure，保留已提交 sidecar 的 revision，不伪称回滚或重跑。
- [x] MCP async hooks：native root／child 以完整公开 operation 绑定 owned Writer
  factory，经 Dispatcher 透传后排队，采用同一账本、源结算核验与消费证明。
  MCP-only child 也支持 active polling；真实 stdio MCP／Deno 覆盖 active、idle、
  host 重建、取消、关闭、权限拒绝与错误不执行成功 hooks。显式 native_tools:false
  保留独立 callback，不从 request／tool-call ID 重建身份，不重复包装 native 资源。
  child 测试使用明确静态 grants，不计作受 #100 阻塞的动态 manager 委派。
- [x] Hook 关闭：命令 worker 在 OS launch 前向 owned AsyncRuntime 注册；关闭／
  owner death 等待 managed OS cleanup 完成，独立于八个 async slots／observers。
  已关闭 runtime 拒绝启动，已完成 hook 的 detached helpers 保留；SessionEnd 在
  async join 后由最终 shutdown 同步持有。挂起真实 worker 的回归先失败再通过，
  root／child 生命周期和完整联合检查通过；此修复不解除 LocalCommand #103。
- [x] 严格hooks退役：shutdown_confirmed要求实际Runner的单向有序cleanup报告与
  normal DOWN，legacy shutdown仍幂等best-effort。重复monitor独立join；normal Task
  return不能掩盖kill失败／异常／缺报告，Linux managed group观察失败保留actual cause。
  已完成hook保留detached helpers，其仍存活时不确认retirement，不改变既有输出行为。
- [x] Live metrics：Runtime 先读 raw journal facts，再按公开 Agent status 的精确
  session／turn／request 身份保留 running，冷恢复仍将未完成项标为 interrupted。
  真实原生 Plan 后 held Provider 的 WebSocket／Chrome reload、实际完成／reload、
  SIGKILL 后完整新 BEAM resume／reload 均通过；不追加 interrupted terminal fact，
  Provider 四次与日志 hash／mtime 不变，原 journal 前缀不变。
- [x] Codex 非空 block／stopped 结果呈现：采用 1.10.37 的 #102 公开协议。
  root／child × direct／真实Deno nested 八项功能验收覆盖下一Provider、后续turn、
  canonical JSONL和资源重建。Plan从实际Store结算确认，显示error仍保留已完成计划。
- [x] 显式空 stopped text：采用1.10.38发布的
  [backplane#107](https://github.com/gsmlg-opt/backplane/issues/107)，保留精确空文本、
  真实结算和canonical Plan，不填充默认文本或伪造效果错误。四项回归先失败再通过。
  pinned 14-event catalog没有PostToolUseFailure，suppressOutput／updatedMCPToolOutput
  也不受pinned Codex支持，不计作缺失实现。
- [x] Plan：读取实际公开 Plan 状态，确认的 root/nested 更新写入 canonical
  tool result；详情栏显示并按 raw journal 所选分支恢复，保留 compaction/reset 前
  的计划且排除 sibling，不伪造 nested invocation；失败 outer call 不发布未确认更新。
- [x] Child Sigma 权限 JSON reply envelope、独立 Runtime 审批通道、terminal
  feedback 持久化与下一 run seed；不得提前插入未完成 assistant/tool batch。
- [x] Managed native child Session 与 shared collaboration manager：采用已发布
  [backplane#86](https://github.com/gsmlg-opt/backplane/issues/86)，每个 child 自有
  Session/Command/Plan，由公开 manager 校验并 adoption；foreign Session 仍拒绝。
  root-only 提问/reset 不向 child 开放；fresh binding、真实 context accounting、
  原始 patch、Deno nested Plan、权限拒绝/取消/晚答、成功 followup 保留句柄和
  确认关闭后的重建进入实际 manager 验收。Child deferred discovery已在下列独立功能验收完成。
  早期 #104/#105 导致的 patch skip 是旧版本边界；当前生产 root／child 目录已恢复
  公开原生 apply_patch，raw 输入、结果、Deno 和历史无重放通过独立功能用例。
  既有权限验收仅保留历史，不在当前开发／测试范围。
  #98已采用公开native lookup的invocation-bound拒绝；root／真实child的completed-handle
  direct／real Deno均返回普通not_found并在同turn继续执行命令。三项纯功能通过（seed43151），
  child Store为completed，JSONL完整状态和structured结果相同。未做跨owner权限检查；
  generic error不推导无效果；当时aggregate archive退役受#126阻塞，1.10.48原Error归档回归已通过。
- [x] #99 中断后直接完成父任务：真实child Provider及OS命令停止，roster closed，
  随后直接完成parent成功；无需先followup replacement。
- [x] #100 Child MCP：真实root search/publication后spawn，child实际调用MCP，
  成功followup后再次通过真实Deno调用。initialize一次、tools/call两次；不手动扩大
  parent grants或重绑active Session。Child按本轮实际connected clients将继承函数转为
  deferred candidates，初始catalog隐藏函数，非空时才提供tool_search；搜索经公开
  publication发布。成功followup重建inventory，budget跟随实际Provider目录；完整
  active_tools保留Dispatcher／hooks。六项选中功能覆盖直接／Deno调用、完整schema、
  followup搜索、真实预算及root尚未搜索时的普通spawn／resource读取。
- [x] Child MCP resources：实际继承已连接 clients，仅在原 parent grants 内准入
  三个资源工具；getter 绑定当前 run/incarnation，child 不关闭借用连接。真实
  manager 的 direct／Deno nested、拒绝时无 remote read、成功 followup 且只
  initialize 一次已验证。root reload 后旧 PID／Registry ref 退休，child 通过可信
  owner 查询使用 replacement，初次 server-id ceiling 不扩大；direct／真实 Deno、
  parent idle、下一 parent turn／child followup、旧 binding 拒绝与权限控制均通过，
  initialize 恰为两次，不创建第三个连接。ChildIO 不持有同步调用根 owner 的锁。
- [x] MCP 资源：`list_mcp_resources`、`list_mcp_resource_templates`、
  `read_mcp_resource`；复用当前 MCP clients，保留 server、cursor、内容与错误。
- [x] root MCP资源精确取消：采用1.10.44公开start／await caller-owned handles，
  注册deadline至多5秒，操作保留既有deadline。真实并发stdio的list／template／read三个
  root取消均发送精确通知，另一caller存活、same-client后续读取与单次initialize全部通过。
- [x] child MCP资源立即精确取消：采用#131／#139公开caller-owned sequential scope；
  原list／template／read中断、同client独立caller和parent continuation通过。
  新分页direct／真实Deno在早期page完成后只取消当前pending page，不派发后续server。
- [x] 上述scope完整退休：1.10.50 #141公开durable resource_scope_retirement已接入，
  原两项最后retire_host通过；没有本地proof parser、虚构receipt或共享client关闭。

- [x] 普通MCP结构化结果：按Codex对照版本9a8a85b将非null的`structuredContent`优先编码为完整
  JSON，替换会截断的Elixir inspect及原text-first优先级。root／实际managed child、direct／真实Deno、
  下一turn／followup及Writer-flushed JSONL读回覆盖80条payload记录、原文Unicode／CRLF／空白、
  null／boolean、缺省／空content、带text摘要的structured输出及普通isError结果；
  原始envelope仍在metadata。另两项root／实际managed-child验收确认真实Deno中的
  普通isError结果以`value.is_error`返回，Promise fulfilled，同一JS继续调用MCP；同turn
  direct、下一turn／followup与Writer-flushed JSONL重复读回完整nested结果且不增加调用。
  该JSON-safe map的验收独立于#111原生Error struct路径；后者已采用1.10.42修复并通过
  下述direct／真实Deno命令句柄回归，原先RED保留为历史证据。
  没有structured输出时保留原text/image投影；typed-media／
  encrypted-content特殊路径仍未对齐。两项回归先RED后GREEN；独立客户端／冷BEAM证据见下项。
- [x] 普通MCP未知内容fallback：按同一Codex版本将embedded resource、resource_link和
  未识别块编码为完整JSON文本，替换Elixir inspect；保留混合块顺序、全部字段和namespaced metadata。
  新增root／实际managed child两项先RED后GREEN，经过direct／真实Deno、下一turn／followup
  及Writer-flushed JSONL重复读取；读取不增加MCP调用或改写文件。六项MCP回归与#97
  独立fixture联合7项通过。该文本fallback不代表typed-media transport已完成。
- [x] MCP JSON独立4629 WebSocket／Chrome验收：每客户端两root turn及真实child followup，
  root24＋child16共40次Provider、16次MCP调用；四份journal保留80条完整payload、原文
  Unicode／CRLF／空白、null／boolean、有序资源／link／未知块与raw details。
  Chrome自主创建与发送，两prompt间reload后可继续，成功工具卡保留第80条和resource内容。
  实时V1事件为有界预览：首轮16588-byte nested JSON只投影4096字符，已保留最初客户端错误
  地按完整JSON解析的失败证据，并单独核对其精确prefix；不重放已完成首turn，仅续发第二prompt。
  实际session.dump在宿主落盘完整artifact，ACK只给路径；不能声称完整dump经实时wire传输。
  BEAM PID1776565完整退出，新PID1786340后Protocol resume/attach/status、Chrome恢复与dump
  读取仍为Provider40／MCP16；四份journal及Provider日志bytes／hash／ns mtime均不变，
  MCP只追加连接初始化，两个root dump前后字节一致。LiveView connected、console无warning/error、
  无横向溢出，served JS与本地产物SHA256相同。自有服务／页面已关闭，4580/PID815717未动。
- [x] 根 `tool_search`：已采用 #87/#88 的 metadata search/owner fencing。真实
  connected MCP 工具作为候选，按当前 binding 延迟 publication，后续 Provider 与
  Deno nested 调用使用更新目录；大于50项 inventory、跨run、刷新、same-batch
  guessed call、取消和过期generation均有集成验收。仅非native MCP保留eager；native
  child另按父级已提交目录建立deferred snapshot，不扩大父级目录或reset私有Runtime。
  #97通用discard恢复已有1.10.37正式修复；独立ChildIO／public Session fixture通过
  普通settled outer error→同run重新搜索→完整schema→实际Dispatcher/MCP调用及
  canonical历史验收，1.10.38亦通过；未改生产接口／settlement。当前生产目录中只有
  Code Mode消费nested dispatch，正常JS返回始终是outer success；真实Deno throw
  属uncertain并结束run，post-hook呈现也不改变publication采用的actual outcome。
  因此当前没有普通outer-error产品触发器，不再将其列为待寻找的root／managed-tree
  验收缺口；未来若引入具备该语义的真实工具，再补实际产品验收。独立fixture仍不
  代表该产品路径，不新增注入API、本地搜索器或依赖私有状态reset。
- [x] 原生 `view_image` 结果内联至原 assistant 工具卡；保留文本/status，纯图片
  同样可显示。工具结果独立校验每图/合计10MiB、最多4图及合法animated GIF；
  上传策略保持原限制。实际浏览器加载与reload证据另列验收记录。

## 其余工具 families

- [x] 异步交互：`request_user_input_async`、`send_message_to_user_async` 接入根
  Writer-owned durable inbox，确认成功调用后落盘；reply/dismiss 的 session/leaf
  fencing、disk ACK、精确重试 receipt、active steering／idle 新 turn、canonical
  与精确Runtime admission/checkpoint共同消费证明、uncertain 不自动重投已实现。
  `runtime_admitted` 单独保存目标run／Runtime消息ID，缺checkpoint或prepare失败不误消费。
  初始prompt hook保留Runtime admission ID，完整canonical字段仍由现有map还原；
  修复idle已送达却因ID改写显示unknown，消费校验没有放宽。
  分支投影排除 sibling facts，cancel/fail
  关闭问题，成功完成后仍允许晚答；Web 卡片和 `async_interactions.v1` 已接入。
  [backplane#89](https://github.com/gsmlg-opt/backplane/issues/89) 已随 1.10.36 采用，
  实际 Engine／Writer／Protocol／LiveView 回归覆盖可信独立 identity 与恢复；
  Runtime accepted、宿主已落盘、admitted 与 consumed 保持不同语义。
- [x] Inbox 保留不设终身card／fact上限；2051 cards／4100 facts回放、去重和分支
  通过。完整题目与原文答案按独立预算保留：单答案32KiB、合计96KiB、encoded128KiB、
  完整reply256KiB、reply_saved384KiB，其余fact128KiB。
- [x] Inbox 出站版本化分页：`async_interactions.pages.v1` 与旧整包模式互斥，
  selected-view SHA256 revision、summary pages、12KiB base64 JSON chunks保留完整
  card；每次query校验当前revision，page按实际wire bytes缩小。通知仅作失效提示；
  resync绑定subscriber／Agent／session／mode，失败快照不解锁。成功mutation后的
  snapshot失败仍保留ACK；malformed reply／struct card明确拒绝。
- [x] 大答案入站分块上传：`async_interactions.uploads.v1` 要求 pages 模式；
  12KiB raw chunks、完整length／SHA256、显式commit；每Agent最多8份／每份256KiB／
  首块起固定5分钟，重试不续期。接收不reconcile／写journal／调用Provider；commit
  校验当前session／leaf／visible card及原有完整reply schema，再复用durable admission。
  完整buffer保留到原TTL／cancel；重启丢失，重新上传后仍复用durable去重回执。
  `admitted`落盘失败保留真实dispatching receipt及错误；无saved reply的unknown不假ACK。
  最终64KiB／collection200／string32KiB和原有answer budgets均不放宽。
- [x] 冷启动恢复：真实客户端完整停止/启动 BEAM 后恢复 async cards 与 hosted
  metadata，重复 reply、reload 不增加 Provider/HTTP 调用。Store 从固定已部署模块
  inventory 加载词汇，保留 `[:safe]`；独立 fresh-BEAM 回归验证完整快照和 unknown
  atom 拒绝。辅助 async facts 不生成额外执行分支，真实 fork 继续保留。
- [x] 上下文：`get_context_remaining` 使用实际目录、当前消息与 Provider 输出
  reserve；`new_context` 在下一模型请求前持久化分支窗口，支持后续 turn、重启、
  fork/retry、compaction 和 Engine 退出后的晚提交恢复；独立 WebSocket/服务重启验收。
- [x] 本地环境：`wait_for_environment` 已接真实command-runtime启动。CodexResources
  为实际资源generation生成ID并保存starting／ready／failed；PlainCommand异步执行
  既有LocalCommand初始化和Native capability检查后发送真实回执。独立owner可在启动
  期间响应公开Readiness轮询；command调用排队至启动完成，失败保留原typed error。
  Root／child Provider及context_remaining采用同一动态environment_context，支持
  custom system prompt、跨turn／followup复用及关闭后新ID重建，历史不重造环境。
  五项功能覆盖真实启动回执延迟、root／child direct／Deno、实际command、JSONL、
  普通timeout配置错误及关闭前未发布ready。早期failed／closed map仅超时的缺口已随
  1.10.45 #128解决，结构化startup-failed／closed结果的消费者验收见下文；
  PTY仍按job启动，不推导sandbox readiness。
- 当前范围排除 `request_permissions`、安全／权限及沙箱加固开发和相关测试；
  保留已有YOLO默认和适配器，此项不作为当前执行的验收门。
- [x] Plugins2目录与持久请求：可选settings.plugins.registryUrl或可信native_plugins
  snapshot接入root／managed-child及followup；未配置时不暴露这两项工具，默认数量不变。
  PluginResources通过公开PluginProtocol HTTP catalog读完整原文；每requestsRoot一个
  application-owned writer保存requests.json。四项原始参数、registry与精确Runtime
  invocation形成durable host回执；同一调用精确重试、writer replacement不重写。
  Session关闭不拥有writer，历史／重开不重放请求；HTTP普通错误可继续，落盘不确认
  保留实际unknown_outcome，不自动重试。五项插件功能与五项环境功能联合10项通过
  （seed261128），覆盖root／child／real Deno、跨turn／followup及Writer历史重开。
  独立4631 Protocol／Chrome从普通settings加载配置和默认requestsRoot，各完成root两轮与
  实际child followup；Provider34／HTTP14次形成10条持久请求和4份journal。9项root工具
  wire结果保留完整canonical内容；两个root的session.dump artifact在冷恢复前后逐字节相同。
  reload／完整BEAM退出并换新PID后，7份journal／requests／调用log bytes、ns mtime和
  inode均不变，无新effects；Chrome恢复9张成功卡与requested正文、connected、无overflow
  或console warning/error，served JS匹配本地产物。自有服务／registry／页面已停，4580未动。
- [x] Plugins显式本地安装宿主：沿用同一application writer，通过公开resolve／download
  固定release／artifact，先保存installing意图，再发布保留原文和可执行位的包目录及
  installed回执。重复installed请求不HTTP／重写；普通文件失败保留failed及实际cause。
  pending只核对已有完整包后确认，缺包仍unknown，不重下／不启动MCP。显式activate
  创建caller-owned公开Plugins.Session，真实stdio MCP、skill／resource与退出已验收；
  不自动扩大根／child模型目录。插件10项＋环境5项功能联合15项通过（seed261128）。
  两个独立BEAM读回9份文件的bytes／ns mtime／inode均不变；第三个cold BEAM显式
  激活并调用MCP一次，8份安装／请求／HTTP文件不变，实际MCP进程退出。
- [x] 已安装Plugins skills接入：每次真实root／managed-child binding重解析共享writer，
  在已配置registry内固定每plugin最新成功安装release；公开PluginProtocol／Archive与
  既有Skill Protocol解析后，合入skills::list／skills::read，显式区分registry／plugin／release。
  复用不可变Snapshot、分页、完整UTF-8／CRLF与资源清理；当前run内安装到下一binding生效，
  followup刷新并释放旧snapshot。只读不HTTP／写安装ledger，不启动插件MCP或脚本。
  插件12＋installed-skill3＋环境5项联合20项通过（seed261129），覆盖实际root／child、
  followup、writer替换、历史重开、release刷新、完整长文本分页和snapshot释放。
  两个独立BEAM经生产CodexResources／公开ExtensionRuntime读取并释放，24份原文件的
  bytes／ns mtime／inode保持不变，无registry／MCP效果。dev/test严格编译、7文件格式
  和scoped diff检查通过；不是新增安装UI或商业模型验收。
- [x] Plugins产品安装入口：`/settings/plugins`与Protocol `plugins.requests`／
  `plugins.install`共用PluginInstallations和实际application writer。settings读取全局
  configured host，Protocol以plugins.install.v1和live Agent的实际native_plugins
  snapshot定位host，显式nil不回退。读／安装均在Agent callback外；持久requestId
  显式触发，分页revision覆盖完整双ledger，保留requested历史及独立installed回执。
  异步UI保留成功回执后续刷新失败；Protocol完整回执过大时仍返回实际compact success。
  插件14＋installed-skill3＋环境5＋Protocol host3／DTO4＋Web5共34项通过
  （seed261130），dev/test严格编译及15文件格式／diff检查通过。
  独立4673 Chrome明确安装一个native请求，Protocol另安装一个；两个会话下一轮
  读取完整skill，Provider10／HTTP4次，重复installed不HTTP。reload的23份文件bytes／
  ns mtime／inode不变；完整旧BEAM退出／新PID后，两客户端resume及installed重试
  不重放Provider／HTTP，21份插件／包／journal／runtime／log保持bytes与metadata。
  既有2份空skill-invocations侧文件仍为[]，但SkillInvocationStore.recover无条件重写
  inode／mtime，故扩大的23文件冷恢复metadata比较未通过这2项；记录范围外行为而不扩修。
  Chrome显示2项installed、connected、无overflow或console warning/error；自有服务／
  registry／页面均停，原4580未动；没有选择实际registry或验证商业模型。
- [x] Plugins root／child函数目录：每个真实binding持有独立公开Plugins.Session，
  固定installed release，公开函数作为deferred候选交给tool_search，继续使用Dispatcher／
  hooks／完整structured结果。child仅使用parent已committed名称，独立持有连接；
  followup先关旧runtime再刷新。root direct／Deno、错误续行、跨turn、普通关闭、
  历史重开和child direct／Deno followup通过。历史独立4634客户端／冷BEAM／Chrome
  保留六张完整结果卡，无Provider／HTTP／MCP调用重放；此证据不包含native完成新结果。
- [x] Plugins逐组件关闭事实：1.10.44的#122公开Session.close先返回实际cleanup报告，
  再stop同一次memoized attempt。7项独立Runtime功能全部通过，包括原失败回归、
  两个独立binding原错误／单次尝试／另一binding继续，以及真实stdio普通关闭。
  公开verified stdio guardian由本地release alias和CI／release显式构建；本地公开task／
  protocol1 probe及下述本机生产包验收通过；远端runner与其他平台尚未执行。
- [x] 本机Linux生产包的插件组件验收：prod warnings-as-errors、公开guardian构建、
  临时path的mix release、tar打包及重新解压均通过。五官方包均1.10.44；PluginRuntime／
  Dispatcher／Session／MCP Client代码与实际执行的guardian均来自解压包，probe为协议1。
  实际stdio经生产Dispatcher调用一次，完整Unicode／CRLF结果保留；公开close报告确认
  guardian exit0和cleanup，精确两OS进程消失，重复close不新增call。包内app JS与浏览器
  验收产物匹配。证据/tmp/sigma-plugin-completion44-1cpucbw5/release-*；未触及4580，
  不代表其他平台、远端CI、发布、部署或完整native profile的installed验收。
- [x] 实际managed-child／默认stdio helper崩溃：由fixture记录的target／start identity
  精确绑定其packaged guardian，仅让该helper崩溃；public ChildIO.retire保留真实
  PluginSession／component／connection／transport unconfirmed报告、缺失waitpid／pipe／
  successful-helper-exit事实和实际exit137。重复retire同原Error／identity，无新HTTP／
  start／call，root独立plugin继续并完成turn。单项通过；aggregate teardown仍如实
  unconfirmed，target non-running不推导reaping或Runtime ACK，无生产injection。
- [x] 原生安装完成：采用1.10.44的#124 `{:completed, outcome}`；按用户选择，原调用
  在writer外等待现有Settings／Protocol显式安装。新requests保存public plugin_request_id；
  native-installations.etf独立保存原invocation、真实:settings／:protocol来源和实际
  installed Archive或Error。精确成功事实与原binding有效才返回completed／user_confirmed，
  outer request_id仍由Runtime提供；不自动安装、不改旧requested历史。失败／晚到／
  completion落盘失败保留实际结果，host安装成功ACK独立；实际Protocol下一Provider与
  Writer-flushed JSONL完整结果相同，root／child direct／真实Deno和Web已有功能验收。
- [x] 原生完成结果的独立客户端与完整BEAM恢复：自有4674 Chrome自主创建／发送direct
  request，WebSocket走真实Deno；两原调用先保持pending，没有提前Provider／HTTP，
  再由真实Settings按钮／Protocol install完成。public request ID、完整结果、原invocation
  与不同settings／protocol确认来源均核对，下一真实turn读取完整Unicode／LF／CRLF skill。
  live reload及旧BEAM完全退出／新PID、Protocol resume和installed重查无重放，Provider／
  HTTP仍10／4；9份插件／log／journal文件bytes、hash、ns mtime、inode全部不变。
  Chrome保留3张成功工具卡、2条installed，LiveView connected，无overflow或console
  warn／error，served app JS匹配本地产物。自有服务和页面已关闭，4580未动。
  证据/tmp/sigma-plugin-completion44-1cpucbw5；受控Provider／本地registry，不代表
  在线模型、installed release或managed-child archive验收，不累计为额外unit test数量。
- [x] 已开始插件请求取消后的root下一prompt：#135公开plugin_install_wait只包围
  request落盘后的观察等待；精确typed proof从真实Store保全并交公开reconciler。
  direct／真实Deno、late install旧文件不变、fresh catalog／MCP和完整退休通过。
- [x] 原插件child冷重开父级收尾：#133 idle-archive transfer消费者现通过。
- [ ] 新加强的managed-child安装后归档followup：取消／proof／完整退休通过；
  后续新增tool_search超出旧ceiling时明确拒绝，两项direct／Deno最终成功断言保留。

- [ ] TODO（用户暂缓，不作本阶段完成条件）：`web::run`、`image_gen::imagegen`的实际
  配置后端、支持操作和媒体／引用结果，以及实际插件registry来源的选择与接入。
  当前Sigma resolver与Backplane HTTP路由没有对应生产契约，不能从LLM origin推导
  Web／Images API。不继续选择或追问服务；provider-hosted web_search另算。
- [x] Responses图片保真：采用1.10.42的#112公开AI Codec，按实际function/custom
  call配对typed result；MCP bare base64／完整data URI不重复加前缀，保留
  `_meta["codex/imageDetail"]`四种值（缺省high）。native、MCP、History、JSONL保持
  detail和媒体顺序；用户上传策略不变。6项功能覆盖真实HTTP／stdio MCP、root／child、
  real Deno、跨turn／followup和重开；root删除原PNG后仍从历史恢复。#108的Anthropic
  PDF子集不能替代此路径，Responses audio/resources/links仍未支持。
- [x] Provider hosted `web_search`：按 model/provider 的显式配置，向 OpenAI Responses
  传递 cached/indexed/live 声明；单独观察事件，不进入本地 registry/grants。
  完整 native output／actions／citations 持久化，replay 校验 provider/model/endpoint
  affinity，计入上下文；DuskMoon 引用和 `provider_hosted.v1` 已接入。协议保留完整
  metadata，最终 envelope 超限显式拒绝；attach 校验完成前不激活 relay。
- [x] 大型持久 hosted 结果：互斥 `provider_hosted.pages.v1` 从实际 Writer 选定
  raw ancestry 列出全部来源，按 repo/session／leaf／entry/message／完整内容 hash
  校验 revision，以有界 base64 chunks 读回完整 envelope。覆盖 display tail 外、
  compaction/context reset 前和 stopped 会话；读取不启动 Agent/Provider 或写日志。
  live 仅发送 committed-result 刷新提示，不声称恢复 transient 原始帧。
- [x] Hosted HTTP SSE 使用公开 framer 配置承接既有原生 1 MiB 界限；普通
  Provider 的 256 KiB 帧界限、native aggregate/item 和 Protocol wire 界限保持。
- [x] 独立4623 WebSocket／4624实际Responses HTTP验收：1,030,712-byte完整
  metadata经84块重组，含999,996字符encrypted reasoning和30,000-byte中文citation；
  断线续读、精确重试、stale／source／offset错误和模式互斥通过。第二真实HTTP
  input逐字保留原生output；完整BEAM退出／新PID恢复后两份结果hash相同，HTTP
  仍2次且日志hash／mtime未变，原journal字节不变。夹具显式配置大session预算，
  两个自有listener已停止，4580/PID815717未变；不推导在线模型或部署验收。
- [x] Hosted 原生replay保留全部有序output，包括reasoning／encrypted content、
  无search turn和reasoning-only turn；未知item显式拒绝。实际HTTP验证交错顺序、
  JSON持久化、tool output后的精确下一input；Engine followup／Writer reopen通过。
- [x] Metrics JSONL 保留null／boolean原类型，其余atom标签仍为string；修复未知
  usage刷新后变成字面量nil。递归容器与实际JSONL恢复回归、Plan完整刷新对比通过。
- [x] 普通命令 PTY：根／managed child 的 CodexResources 使用 PlainCommand；
  非PTY原样委托公开LocalCommand，Linux PTY每job独立Native helper，真实24×120。
  保留stdin、UTF-8分帧／CRLF、跨turn与child followup、实际Deno、非零exit和回执。
  Native沿用既有环境，尚不支持per-command environment overrides，不启用沙箱adapter。
  helper自然退出先清理剩余slave holder并在既有共同5秒预算内drain至EOF，再发布exit／cleanup；
  job等待最终Native事件和DOWN，公开ACK前保留receipt，host关闭／异常退出回收job。
  writer持有至cleanup／drain完成，避免portable-pty drop写入的newline／EOF回显；
  实际echo-enabled slave holder稳定复现额外CRLF，调整本地释放顺序后5项native输出通过。
  14项adapter＋3项Engine＋32独立Session并发1项＋直接已结束handle错误1项，共19项
  选中Elixir功能检查通过；4项native输出测试通过。该历史19项未计当时#111嵌套错误RED；
  后者现已由1.10.42独立两项功能验收通过，不与历史计数相加。
  4626独立WebSocket与Chrome各5次Provider，真实TTY／中文空白CRLF／exit7、3／cleanup通过；
  浏览器两prompt间reload仍可续写。完整BEAM退出／新PID恢复后，每session三张结果完整，
  Provider与launch文件hash／ns mtime、原journal bytes均未变，无effects重放。
  最终LiveView connected、无console warning/error或overflow，served JS匹配本地产物。
  cold reconnect另记录范围外select_model的_target-only payload异常，手动reload后正常；
  未扩展修改模型设置。自有服务／page已关闭，原4580/PID815717未动。
- [x] 本地环境启动失败公开结果：正式1.10.45已修复
  [backplane#128](https://github.com/gsmlg-opt/backplane/issues/128)。原三项未skip失败断言通过；
  实际PlainCommand validation原因经Readiness立即保留，Control返回普通is_error值，
  native root Conversation／真实Deno后继续Plan，完整paired history经Writer／Log保存。
  closed／unavailable立即not_found，成功root／child跨turn、Deno和关闭新ID范围仍保留。
  故障callback来自实际startup error；没有生产Engine故障注入或新客户端失败验收声明，
  没有新增生产注入边界，也不用本地backend、callback throw、伪ready或加timeout绕过。
- [ ] 其他命令平台、多环境类型仍需适用性与功能验收；本地命令宿主启动已实现并验收。
  先前选定的隔离策略与原生CommandHost／CommandRuntime／launcher均保留为历史准备；
  #95可信bootstrap已发布，生产沙箱切换及安全／权限开发测试不在当前允许范围。
  native 启动器已有 FD mounts、seccomp、owner-death 和真实 Ubuntu payload 验证；
  私有编译摘要快照、Session fencing 和保留 stdin 已测试。CI 固定 bwrap 0.11.2、
  先构建两项 native binary 再编译 Elixir；远端 Ubuntu/AppArmor 尚未执行。
  Nix `/bin/sh`／`/usr/bin/env` shebang 已通过实际 kernel exec 验证：固定 canonical
  interpreter 纳入精确 closure，别名目录只读，拒绝工作区遮蔽或额外别名。
  原生层已验收四个同 workspace 保留命令的独立 mount/PID/net namespace、
  home/tmp 与原始 stdin；定向终止一个 setsid 进程树后，另外三个仍可交互并以
  各自状态退出，新沙箱保留 workspace 文件但不继承私有状态。native 共28项通过。
  该历史测试直接调用启动器；普通生产PTY已在上面单独验收，环境接线仍待完成。
- [x] 本地原生安装包：release-mode native build、全新 prod 严格编译、打包并解压到
  新路径后，将原 source／release build 绝对路径置为不存在。独立 release eval
  证明实际 BEAM 和默认 launcher 来自安装目录，编译摘要／0700／0500／篡改副本
  拒绝及 snapshot 清理通过。两次原生执行验证共享 workspace、全新私有 home、
  host/sibling 隔离、清空 ambient env、内核只读 mount 标志、IPv4/IPv6/UNIX
  socket 拒绝与 exit23；打包 PTY 验证91列25行、原始中文／空白、exit17及cleanup。
  独立 `scripts/verify-release-native-smoke.py` 已接在 Linux amd64 release archive
  解压后／upload前；Python／实际 YAML／Bash syntax与顺序检查通过。证据仅为
  当前Linux x86_64/Nix宿主，不替代远端Ubuntu/AppArmor或生产LocalCommand验收。
- [x] 默认 LocalCommand并发清理：1.10.37已发布#103修复；本批以32个独立
  Session真实保留命令，并发关闭／取消及OS PID退出做功能验收，不重试effects，
  不增加timeout、不串行化生产命令。32个OS PID均退出，16close／16cancel确认，
  原始running settlement保留；当前1项功能验收通过。

## 27 项扩展

- [x] Goal3生产注册：真实Writer／Runtime Store／Session binding、独立Coordinator、
  原样公共Goal context和ExtensionRuntime已接Engine；dynamic discovery刷新保留Goal。
  public backend使用resource_owner内的实际Session binding，direct／real Deno均可用。
  实际累计用量与public MultiAgent child delegation记账；child不暴露root Goal3。
  自动idle走真实普通admission的reserve／release，取消durable defer、真实prompt可resume；
  no-Goal running child的空outbox不要求Goal结算。生产8项功能已通过。
- [x] 终态Goal receipt恢复：采用#109公开ACK，原receipt完整redeliver／去重，commit或
  ACK失败保留cause／outbox，不重放Provider/tools。2项故障及8项coordinator功能已通过；
  这些terminal fixture不代替真实storage_failed child的恢复。
- [x] Goal文件生命周期：8项实际Runtime功能覆盖live／stopped rename、adopt、delete、
  fork及失败reopen／retire cause。`.runtime`和`.subagents`共同移动／rollback，移前退役
  Goal owner、root Store和共享writers；fork按目标真实Writer/header导入完整public
  snapshot，不复制source Runtime receipts。操作失败先reopen实际Store再Goal；解锁失败
  保留已执行文件结果和实际原因。
- [x] 实际child receipt故障恢复：真实child usage write失败、完整Writer admission／
  child Store／原outbox保留；停自有tree并确认真实Provider死亡后，用公开Store.fence、
  Kernel cancel／exact provider-only cleanup_settled协调，不制造tool／child清理证据。
  当前fenced run incarnation可大于原admission／receipt incarnation，原receipt不改。
  两项功能覆盖usage commit／terminal ACK失败，重开Goal／Store／Writer进程后只计13 tokens
  一次、精确ACK仅递增一revision。仅同BEAM进程冷重开，不代表自动manager恢复。
- [x] Goal准备失败收尾：真实run-index I/O失败发生在Session reserved后，公开host先close，
  保留原preparation及实际cleanup错误。功能回归证明失败时Provider未启动，恢复index后
  下一真实prompt可取得新Session／run并完成，旧reservation不再阻断。
- [x] 实际root fenced恢复：修正current incarnation必须等于原index的错误；确认终态后
  允许公开fence提升incarnation，原index／receipt计费身份不改，ACK使用current incarnation。
  两项真实Engine功能覆盖usage write失败、实际Provider DOWN／Session资源close、重复
  Goal commit／ACK失败与生产Agent重开，只计13 tokens一次，下一真实prompt完成。
  独立完整BEAM退出／新BEAM验收同样通过；恢复前后journal和3次Provider log字节相同，
  新prompt才增加第4次请求。这里是明确清理证据后的公开手动协调，不是自动controller。
- [x] Child宿主退役回执：现有Store串行写独立host-retirement.etf，不改普通Runtime
  snapshot／revision／outbox；生产Subagents传实际root Writer header，ChildIO取自身header，
  host lifetime与native Session generation分离。每次bind在extension准备／admission前
  记录精确run、native owner及各自incarnation，保留followup／generation全部membership。
  CodexResources记录actual native close；ChildIO显式retire在锁外join异步hooks并单独记账，
  实际确认后写失败可精确重试，unknown保留原cause。root manager unknown不会被child
  component成功覆盖；terminate fallback不能响应callback时保留未确认，不伪造回执。
  生产close重试在aggregate与child全部确认后只清理对应cleanup_unconfirmed错误；
  failed followup index写入仍保留旧ExtensionRuntime直到实际join后才记录native确认。
  实际child usage失败后，独立确认精确Provider死亡、生产close与全部owned进程退出；
  完整BEAM退出／新BEAM只读Store重开保留exact ledger、snapshot／Goal outbox及8文件
  bytes／mtime，不恢复Agent、不运行Provider／Kernel settlement／Goal redelivery。
  这是component证据持久性验收，不代表自动故障恢复controller完成。
  当前定向联合81项（Coding18／Agent63，seed261084）、生产3项（seed261085）、
  既有Runner生命周期8项（seed261086）及native输出5项全部通过；dev／test严格编译、
  12个Elixir及2个Rust文件格式、diff检查通过。与旧范围重叠不累加，保留实际故障／
  teardown诊断；无安全／权限／沙箱开发测试。证据/tmp/sigma-retirement42-xqfy8xfr。
- [x] Root组件退役接线：实际Writer header与独立root host lifetime进入全部原生generation，
  复用CodexResources的精确bind／close回执。Agent.retire_host在锁外依次close native、
  strict hooks与同步SessionEnd；SessionEnd使用fresh scoped runtime，独立保存completion、
  outcome和warnings，不能以dispatch完成声称handler成功。原ACK／SessionEnd attempt缓存，
  写失败只重试落盘，丢失task result保留unknown且不重跑effect。version2读兼容version1，
  不改旧文件或补造SessionEnd。文件move前退役，失败unlock先建新hook／host lifetime；
  活动terminate避免native回调死锁，保留native未确认，仍做hooks／orderly SessionEnd。
  Plan／无LocalCommand job的代际及文件生命周期验证与下列命令blocker分开。
  完整BEAM退出后新BEAM只读Store：3个run／2代native的version2 ledger与原Runtime
  records完全相同，8文件bytes／mtime不变，Provider仍5次、SessionEnd仍1次；
  不resume Agent／重放effects／执行Kernel或Goal reconciliation，不代替自动恢复。
  本批11项root／host receipt加45项Goal／board／hooks生命周期功能通过，共56项，
  与此前范围重叠不累加。原65项联合检查的1项命令cleanup失败保留，并独立复现#118，
  后续passing seed不抹除失败。dev／test严格编译、7个Elixir文件格式及diff检查通过；
  无安全／权限／沙箱开发测试。证据/tmp/sigma-root-retirement42-5a8lvie5。
- [x] 可靠retained非PTY命令close：公开1.10.42在/proc进程退出竞态返回ESRCH，
  原生cleanup不能确认；已复现并登记Bug blocker
  [backplane#118](https://github.com/gsmlg-opt/backplane/issues/118)。上游
  [d9d2f53](https://github.com/gsmlg-opt/backplane/commit/d9d2f539fababd609464cc438b553aae18018114)
  已修复并关闭issue：单条proc entry的ENOENT／ESRCH均视为消失，继续扫描其余group成员，
  其他读取错误仍保持uncertain。已采用正式1.10.43五包；原seed261088和未修改断言的
  root retirement7项＋32-Session并发close／cancel1项通过，共8项功能测试。
  RootRetirement的#118 TODO已移除，active termination仍独立保留实际未确认结果；
  未加本地scanner、timeout或effect重试。
- [x] Provider真实退出事实：root／child在公开adapter入口、实际Provider调用前，向现有
  Store注册精确run／incarnation／step／attempt identity；Store监控actual caller并将真实
  DOWN保存到独立provider-lifecycle.etf，不改普通Runtime／Goal／journal。写失败保留原fact／
  cause，只重试持久化；旧Store／BEAM丢失的观察保持incomplete，不凭重开补造stopped。
  child explicit retirement须先确认该证据；失败保留ChildIO／Store，精确close重试后再stop，
  避免文件move时遗留旧路径writer。Store.retire拒绝live monitor／pending write时立即返回
  actual error，不等待未发起的shutdown。root／child实际usage故障回归要求对应stopped证据。
  七文件联合功能41项通过；实际child usage故障经完整BEAM退出／新BEAM只读Store，
  exact provider ledger／Runtime／Goal outbox及11文件bytes／mtime保持，不重放效果，
  root aggregate仍unknown。再选11项root／host receipt通过，最终52项功能通过，不累加
  旧范围或计入5项#118命令路径。dev／test严格编译、8文件格式及diff检查通过；
  无安全／权限／沙箱开发测试。证据/tmp/sigma-provider-lifecycle42-dc8j_u35。
- [x] 根provider-only自动恢复：生产GoalCoordinator在终态验证前消费实际Writer header、
  原run index、同宿主全部native代际／async hooks／独立SessionEnd回执和全部Provider
  attempt的精确stopped事实。只允许原active Provider及其exact intent／outbox；其他work、
  uncertain intents或缺证据不改Runtime／Goal。公开fence／cancel／cleanup_settled保留部分
  落盘阶段，精确重试不再fence、不重放effect；随后用原Goal receipt与当前fence ACK。
  实际usage／后续Goal commit与ACK失败、各恢复写入阶段、缺组件或历史Provider事实、
  无Goal普通Runtime落盘失败的非空Provider outbox均有功能回归。
  完整BEAM退出／新BEAM生产重开自动协调，只计13 tokens一次；新prompt前journal、
  Provider log、两种ledger及run index共5文件bytes／ns mtime不变，只有Runtime／Goal
  记录变更。replacement保留committed context并增加第4次Provider；再换新BEAM重开，
  8文件bytes／ns mtime及计费不变，Provider仍4次。证据/tmp/sigma-root-recovery42-2fh6rfug。
  最终8文件功能联合50项通过；dev／test严格编译、3个变更Elixir文件格式与diff检查通过。
  该范围与此前生命周期计数重叠，不相加；故障注入／teardown诊断保留。
- [x] child provider-only Store／Goal恢复controller：GoalDescendants加载retained receipts前
  调用shared RunRecovery，分别核对原Writer admission／Goal accounting thread和实际child
  transcript header，以及全部native代际、async hooks和每个Provider attempt的真实退出。
  公开fence／cancel／cleanup保留原receipt身份，重复load不refence；实际usage／ACK失败、
  missing host／Provider事实和root／journals不变有3项新增功能回归。root／child联合14项通过。
  早前实际durable child故障的副本在新BEAM经生产loader及公开Goal记账，只改child Runtime／
  Goal两文件，其他9文件bytes／ns mtime不变；再换新BEAM，11文件和计费不变，Provider仍4次。
  原始证据未改，自有BEAM均退出。此为独立child Store／Goal验收，不恢复Agent或root manager；
  该1.10.42组件验收中GoalCoordinator仍先拒绝unknown root；当前prospective完整恢复见下一项。
  证据/tmp/sigma-child-reconciliation42-iseu9a_1。
  最终8文件功能联合53项通过（seed261116），与此前50项重叠不相加；新测试在停自有tree前
  通过公开cancel等待root真实unknown结算，保留原结果断言，避免仍在cancelling的fixture竞态。
- [x] prospective provider-only失败child的manager／Session协调、替代root准入与fresh-BEAM恢复：
  已接正式1.10.43 [backplane#119](https://github.com/gsmlg-opt/backplane/issues/119)。
  LifetimeRecovery在root transcript旁串行保存immutable admission／configuration／inventory、
  relative Store refs、精确Conversation观察与实际DOWN、公开manifest／receipt及原receipt版本。
  Writer以immutable journal header为身份，rename／adopt不以可变route别名替换；manager保留各自
  原admission身份。借用Store不拥有其生命周期，退出只退役自行打开的读者。
  先确认各native generation、async hooks及全部实际Provider退出，再停止精确failed Conversation、
  观察DOWN并通过shared RunRecovery的public fence／cancel／cleanup协调provider-only Store。
  Registry→child Session→最深child→ancestor→manager→root Session必须取得每个实际public ACK；
  confirmed receipt本身不等于ACK。Goal ACK推进revision后，按同样顺序在准入前reseal，
  原ACK仍关联immutable原receipt版本。root native／hooks／独立SessionEnd仍需单独证明。
  历史unknown_outcome、uncertain Provider intent及原receipt attribution不改，只准入保留committed
  history的新root；不恢复旧执行、不重放效果。缺失legacy事实和其他未结算work仍拒绝。
  真实nested failures、successful same-child followup、各ACK缺失、receipt／admission写失败和
  fresh-BEAM生产重开已有功能回归；现有5项child usage／ACK回归改用生产close，并保留精确
  fencing／去重／缺失组件断言。8项文件生命周期回归涵盖rename修正。
  独立完整BEAM验收实际Deno→command只写一次，真实child usage失败后退役并退出；新BEAM
  生产resume只计13 tokens一次，新prompt保留原context，Provider仅6→7次，命令marker不变。
  再次独立冷重开无prompt，15文件bytes／hash／ns mtime不变；随后orderly close只新增一个空
  新root host的confirmed hooks／SessionEnd，原host和其他14文件不变。最初要求连新host退役
  都不得写文件的harness断言错误已记录，未修改产品语义。证据/tmp/sigma-alignment43-2i8m7rnx。
  #117归档同身份followup不包含在该边界；不宣称任意unknown tool／dependency自动恢复。
- [x] 已归档child公开导出／恢复：采用#117 API，ChildArchives复用LifetimeRecovery
  writer保存不可变完整export，只选durable roster的原Sigma run；parent-first恢复
  保留child Session／agent／origin，followup分配新执行run。普通重复turn复用manager。
  1.10.44允许完整assistant metadata；本地恢复所开的child Store显式交接给ChildIO，
  先link再recovery unlink，后者仅borrow，child负责retire并保留normal／abnormal cause。
  handoff3项及Goal已记账rename／followup、重复turn和精确选择通过。
  独立producer／consumer两个新BEAM通过真实rename、完整Unicode／CRLF metadata、
  原child身份、fresh followup，无prompt重开时journal／effects／原Goal记账不变；
  恰好三个新Provider response增加6tokens，旧工作不重复计费。确认公开retirement后
  仅停止自有repo；此为受控Provider，不代表real-Deno cold archive或插件故障关闭验收。
- [x] 普通native Error归档无损结果：1.10.48上原#126回归通过，保留expired handle错误、
  real Deno续行、rename、原child／精确历史／Deno followup及单次command marker。

- [x] Memory add/list/read：`memories::add_ad_hoc_note`、`memories::list`、`memories::read`，
  真实用户存储、共享writer、Session fencing、权限、逐字节exclusive写入、分页、
  direct/Code Mode、跨turn/Session、writer重连、generation根固定已实现。
  模型结果使用完整JSON，保留path/行号/截断字段，已在真实下一Provider请求和
  后续turn seed回归中验证。
  独立WebSocket与Chrome完成direct/真实Deno nested、完整隔离BEAM停启后的
  resume/fresh Session和reload验收；note hash/mtime不变，无历史写入重放。
- [x] `memories::search`：采用#92已发布tagged schema，真实MemoryResources共享
  writer支持any／同一行全部／给定行数内全部、最小窗口、Unicode规范化、上下文、
  排序和分页。8项功能验收包含真实Engine／下一Provider JSON、Deno、writer重开、
  跨turn与fresh Session。Memory共4项；连同后续Goal／Board，27项扩展均已有适用宿主注册。
- [x] Skills：`skills::list`、`skills::read`，实际 executor catalog、manual/disabled
  规则、只读 immutable bundle、分页、Session fencing、撤销与失败清理重试。
- [x] History：`history::list_windows`、`history::list_items`、`history::read_item`、
  `history::search_contents`，读取真实Writer选定raw ancestry，包括compaction／reset前。
  header／context-window entry构成稳定window ID，message entry及call序号构成稳定item ID；
  逐tool-call分项、namespace／角色过滤、literal搜索、Unicode scalar分页与独立图片block。
  root／managed child使用实际owner目录；ChildIO读取在Subagents锁外完成，支持Registry引用。
  省略agent_name绑定精确当前child Session，同名归档按最新durable registration event选取；
  live owner错误保留，确认已死child可读其精确持久文件。后一个同名规则是Sigma解释。
  DirectModelOnly在真实Deno中排除；remote encrypted history未实现并已由用户暂缓，transient checkout
  仍须下一次conversation append才成为持久选择。读取不重放effects。
- [ ] TODO（用户暂缓，不作本阶段完成条件）：remote encrypted History的真实后端与
  encrypted envelope接入；保留本地History4的现有实现与验收范围。
- [x] Notes：`notes::list_files_by_prefix`、`notes::read_file`、`notes::search_contents`、
  `notes::append_to_file`、`notes::write_file`；同一root rollout共享application-owned
  serialized writer，存储`<root_transcript>.subagents/notes.json`，每次读真实JSON。
  relative／cross-agent virtual paths、包括空文本的精确replace／append、每file一百万
  UTF-8 bytes、保留LF/CRLF的inclusive正负物理行、排序及显式limit已实现；无隐式result cap。
  只读不创建目录／文件；rename／adopt／delete跟随现有subtree，fork独立。
  复用file sync＋atomic rename，不宣称directory fsync／跨node排他；unknown不重试。
  DirectModelOnly在真实Deno中排除；`notes.thread_hint`未实现。
- [ ] TODO（用户暂缓，不作本阶段完成条件）：Notes full-context提示`notes.thread_hint`。
  pinned Codex通过真实`alpha/notes/v2/thread_hint`后端，
  使用session ID／agent path取得非空、至多4000 UTF-8 bytes的text。失败／空／超大则省略；
  它进入独立developer `token_budget.context_window`的notes.thread_hint，与first／current／
  previous窗口UUID一起贡献full context，不是第六个Notes工具，也不在普通增量重复。
  Sigma缺实际backend和full-context投影契约；public ConversationAdapter context callback
  是可评估接点，缺专用ExtensionRuntime hook本身不构成已确认上游blocker。
  不把上游测试的recent-notes fixture编成生产摘要算法。
- [x] 消息板9项：`collaboration::create_channel`、`get_channels`、`list_threads`、
  `search_posts`、`read_thread`、`read_post`、`subscribe`、`unsubscribe`、`post`；
  root／child按真实Session／Subagents membership／Writer header共享board，独立于V2六工具。
  每call重读JSON，变更file-sync＋atomic rename后才发公开active-only通知；精确retry不
  重写／重投。通知在Subagents锁外按实际manager／agent／run／incarnation发送；best-effort
  失败保留成功post result与真实log，idle不启动、不用普通queued替代。#110已消费。
  5项生产功能覆盖全部工具、Deno、Unicode/CRLF分页、root→child、child→root及sibling
  消费／未消费terminal／idle、普通queued不变、真实rename／fork后读写及fork独立。
  7项Runtime生命周期、8项Store功能保留独立证据。
- [ ] 消息板原始128KiB argument envelope；decoded/compact JSON无法恢复原raw空白。
  保留显式缺口，不扩展当前禁止的安全／权限开发与测试。

普通命令已结束handle的direct／real-Deno两项功能均通过1.10.42：正常工具错误让
nested Promise fulfilled，保留完整错误并继续执行另一命令。#111不再阻塞；无本地
encoder／dispatcher绕过，不涉及权限或foreign handle测试。

## 每个实现边界的验收

当前live recovery接入后的联合功能检查：18个纯功能文件 **134项／0 failures**（seed43131），
另在3个文件精确选择6项native child生命周期与2项hosted功能，**8通过／17排除**（seed43132）。
覆盖普通shutdown到生产重开、下一真实prompt自动退役／替换host、恢复中取消、receipt写失败只补存、
prepared资源只释放一次、剩余accepted followup推进和retry context还原。原hosted准备失败后重开及
无transcript的unknown恢复错误两项先在live-before源码BEAM精确复现，再以配置校验前置和
结构资格检查前置修正；保留原断言，不把缺失indexed Runtime当作未执行。故障／teardown日志保留。
自动Goal在public idle预约前检查host。此前1.10.43的真实characterization确认release后的
provider配置失败没有Runtime／Provider，但Goal仍already_reserved（seed43133，另8项排除）。
现已采用正式1.10.45的
[backplane#127](https://github.com/gsmlg-opt/backplane/issues/127)：coordinator先监控真实Task，
纯provider配置位于hooks／startup children／Runtime之前，host原子gate区分准备、effects、
取消／supersede和seal。只有实际DOWN且未打开effects，才提交完整identity的公开no-start
attestation；Agent join精确结算ACK后才发terminal／agent_end并开放后续准入，不运行interrupt
hooks。失败保留seal和实际cause，只重试持久化。生产Engine的配置失败、下一真实prompt及
显式用户mutation后的新自动run保持同一Goal／thread，agent_end后立即读到receipt，不靠轮询。
旧1.10.44 Goal完整schema只在内存补两个map，读取不改bytes／hash／mtime／inode，首次真实
mutation才推进原revision；公开fork保留独立完整snapshot。effects gate后hook／Session失败
仍须真实恢复证据；不由缺失indexed Runtime推断未执行，不withdraw after release、reset Goal
或伪造receipt。Goal owner重启后未提交的旧reservation不能靠该API重建。
实际WebSocket和浏览器Message／Send／Stop分别完成child Deno命令与usage故障后的新prompt恢复，
无需显式retire_host；两份旧unknown snapshot不变，各追加retained child13＋新response13 tokens。
最终Provider12次、command2次、Goal117 tokens。完整BEAM替换后Protocol resume与浏览器reload
不重放，Provider／command的bytes、hash和ns mtime不变；另一新BEAM确认原snapshot及记账不变。
LiveView connected，无console warn／error及横向溢出；均为受控Provider，未宣称在线模型验收。
dev／test严格编译、8文件format check和git diff检查通过。自有4632服务／页面已清理，4580未动。
证据/tmp/sigma-client-recovery43-p96z0kir；没有安全／权限／沙箱开发与测试。

此前#119接入后的联合功能检查：13个纯功能文件 **93项／0 failures**（seed43121），
另在native child混合文件只选6项生命周期用例，**6通过／11排除**（seed261146）。
receipt写失败要求aggregate仍unknown、携带同一实际cause且writer保留到confirmed close；
rename回归修正新Writer误用route别名的问题，8项文件生命周期均通过。独立只读复审无剩余发现。
dev／test严格编译、19文件format check与git diff检查通过。证据/tmp/sigma-alignment43-2i8m7rnx。

本轮验证有一次已报告偏差：worker误跑两个完整混合文件，包含权限用例，90项／6 failures；
已告知用户并停止worker。没有修改安全／权限／沙箱源码或测试，后续未重跑此选择。
其中旧ChildIO metadata exact-key失败在候选前已存在，保持未改；其他5项child恢复测试已按
生产close迁移并限定验收。当前93＋6与历史选择重叠，不累计旧测试数量。

正式1.10.44最新去重定向功能为59项：54通过／5项保留上游失败。
资源＋PluginRuntime14项中child取消3项受#131；archive＋handoff7项中Error export1项
受#126；精确选行的ChildIO／MCP8项通过；plugin21＋Protocol4＋Web5中idle restored
child收尾1项受#133。原plugin20＋Protocol4＋Web5联合采用seed43153；新增真实child
stdio helper崩溃一项单独通过，未把重跑计为新用例。显式host reconcile回归先RED后GREEN，
原native失败事实不改。
不累计重复运行和历史通过数，无安全／权限／沙箱相关开发或测试。dev／test严格编译、
26项授权Elixir格式、13项lock审计与diff检查通过；661文件基线中仅28个授权已有文件
变化，另增1个功能测试，其余hash不变。独立两BEAM归档续接与公开trace见上文；
本机Linux生产归档和installed插件组件另已验收；其他平台、远端CI及在线模型仍未验收。

此前#119接入前正式1.10.43的新BEAM联合功能检查为7文件 **44项／0 failures**（seed261144），另选
managed child生命周期6项通过（seed261146，混合文件11项排除）。旧handle回归按实际
canonical not_found与continued Provider修正先前错误的unknown预期，仍要求后续真实命令、
child／root完成和confirmed close。该次选行检查排除安全／权限用例，actual active terminate诊断保留。
撤回archive候选后首次同Mix BEAM检查有36项失败，原因是旧已加载.app模块列表仍引用
已撤回模块；实际生成.app正确，新test编译／BEAM通过，Store源码未改，原失败日志保留。
这两组与#118原seed8项存在覆盖重叠，不把旧范围重复累计。

假设上游修复后的consumer准备另有37项纯功能联合检查（seed43141）：31通过、6失败。
失败分别是#128的Readiness／Control／starting→failed三项，及#126的普通rename、
Goal已记账rename、plugin-child冷重开三项；全部保留原功能断言，不skip。Goal用例先确认
真实child用量＋2与committed outbox为空，再在公开exporter失败。fixture先后修正非法task名、
缺cached计数和Message struct读取，未改生产记账或归档行为。PluginRuntime独立6项通过，
包括partial preparation已启动进程的显式cleanup。相邻26项功能通过，teardown仍记录#126
未确认退役，不能把0 failures当成aggregate close成功。该范围与旧结果分开，不重复累计。

此前1.10.42组合功能回归为 **56项／0 failures**（seed261055）：Goal production8、
Goal lifecycle8、terminal recovery2、coordinator8、board production5／lifecycle7、
Responses图片6、command handle2、MCP完整结果6、discovery discard1，实际child receipt恢复2、
Goal准备失败收尾1。
dev/test `compile --warnings-as-errors`、40个相关Elixir文件格式及`git diff --check`均通过；不运行全量中
包含安全／权限／沙箱的suite。后续源码变动须补受影响功能回归和最终格式／diff检查。

独立4630的真实Protocol和新建Chrome会话各完成Goal、Board、managed child、native／MCP
图片及real Deno。4个journal累计34次Provider、8次MCP工具调用。完整BEAM退出
（3729854）后新BEAM（3736894）resume／reload：两个Goal均complete、tokens_used=208，
child历史恢复；无新prompt／tool event。Provider34／MCP8不增，MCP只追加初始化；
4个journal及Goal／Board／Runtime的bytes和纳秒mtime不变，skill-invocations sidecar仅
mtime刷新、bytes不变。完整Protocol dumps字节相同，工具detail／MCP metadata保持。
Chrome三张image全部decode成功、connected、无console warning/error及横向overflow，
served JS与本地产物hash一致。自有服务／页面已关闭，原4580/PID815717未动。
这是controlled Provider／真实本地客户端及冷BEAM证据，不等同live model、故障child恢复、
发布或部署；没有安全／权限／沙箱开发或测试。

此前1.10.38等批次的证据和计数保留如下，不与本批累计相加。

本轮结构化MCP结果两项功能回归与#97公开Session/ChildIO回归联合 **3项／0 failures**，
seed261039。前两项先在原inspect fallback下因无效／截断JSON失败；text-first优先级
也有独立RED，再在完整JSON及结构化优先后通过。未重跑下述58项，不将重叠或历史测试数相加。

此前1.10.38联合功能范围为 **58项／0 failures**：environment／普通命令／PTY／
并发cleanup／board writer与文件生命周期／presentation七文件50项，选中child
deferred六项，实际HTTP function/custom空输出两项。四项空stopped回归先在旧版
明确失败，采用公开修复及移除旧诊断旁路后，全部12项呈现用例通过。混合文件只跑
指定功能tag或精确位置，未运行安全／权限／沙箱用例；dev／test严格编译与相关
文件格式／diff检查通过。故障注入日志仍可见，不声称日志无error。

独立4628（1.10.37）WebSocket／Chrome各执行root7＋child5次Provider，实际四次
命令effects与四个稳定独立environment ID。reload／完整冷BEAM恢复保留原journal
前缀和完整结果，另三份journal及Provider／effects logs bytes／hash／ns mtime不变。
浏览器重连追加一条同模型model_change；最初整文件不变断言确实失败，已定位为
既有LiveView表单恢复，不能声称整journal hash未变。无Provider／命令重放。

独立4629（1.10.38）WebSocket／Chrome各完成root与实际managed child的direct／
nested Plan，共22次Provider、8次实际hook、8份精确空文本结果。刷新／完整BEAM
退出及新PID resume后，原journal前缀和Provider／hook logs bytes／hash／ns mtime
不变，仅一条同模型model_change。六张成功root卡片及确认Plan保留，LiveView
connected、无overflow或最终console warning/error；日志含受控Provider worker的
:killed退出。自有两批服务／页面均已停止，4580/PID815717未动；不推导在线模型、
安装包、发布或部署。该范围与前批重叠，不累加测试数。

本批15项选中功能联合通过：6项child deferred、8项board writer、1项上述#97独立
ChildIO／public Session fixture，未运行
同文件中的权限／安全测试。两个初始deferred断言在旧实现RED，三个空inventory普通
spawn案例在修正前RED；最终全部通过。dev／test严格编译、五个相关Elixir文件格式与
diff检查另验。独立4627 WebSocket和Chrome新会话各完成root search／spawn、child
search／直接调用、followup新search／真实Deno；合计Provider26次、MCP实际调用4次，
initialize各root一次。完整BEAM退出／新PID恢复后，四份root／child journal和Provider
日志bytes／hash／ns mtime均不变；MCP仅重建两个root连接，没有函数／Provider重放。
两个child各四份完整tool results，Chrome保留6张成功卡片、connected、无overflow或
console warning/error；初始fixture日志含supervised Provider worker的:killed退出，
不声称日志全无error。自有两个BEAM／page已关闭，4580/PID815717未动。

History／Notes本批共 **52个不同功能用例／0 failures**：新History5／Notes11／
Engine集成6，加patch3／Memory search8为33项（seed673067）；19个当前测试名生成的
Agent／Web选择器全部通过（seed977385），目录精确断言已纳入archive9。范围包括实际
root／managed child／followup、同名child冷恢复、图片JSONL／Provider和真实Deno排除。
独立4625 WebSocket执行9工具以及new_context后旧History／Notes读取，共14次Provider；
Chrome新会话执行9个成功卡片，共10次Provider，完整中文／空白／CRLF及读回JSON正确。
刷新与完整BEAM退出后新PID恢复，两个Notes store和Provider的hash／ns mtime不变，
两会话原journal前缀bytes保留，Provider仍14＋10次，无effects重放。served JS与本地artifact
相同，LiveView connected、无横向溢出或console warning/error。自有服务和page已关闭，
4580/PID815717未变。回归日志有cancellation／owner-exit诊断，0 failures不代表日志无错误。
本批不涉及安全／权限开发测试、在线商业模型、发布或部署；与此前计数重叠，不累计。

此前1.10.37仅做功能验收：四个新功能文件20项，加从当前源码按test名称生成的
19个旧Agent／Web精确选择器，共 **39项／0 failures**；覆盖Memory search8、
非空presentation8、patch3、32-Session并发cleanup1和实际MCP／Deno、父任务完成、
Web目录／chat及hosted HTTP／history。dev/test严格编译、24文件格式与diff检查通过。
旧选择器批次出现teardown cancellation／owner-exit诊断，0 failures不代表无日志错误。
格式化后旧行号曾误选一项private-error透传用例，已改按当前测试名生成位置，不计入
上述功能验收；之后没有重复执行。用户最新范围排除安全／权限开发与测试，已有
相关证据只作历史保留。本批没有新浏览器／在线模型／发布／部署验收，4580/PID815717未动。


此前1.10.36联合scope为109文件、**1,366 tests／0 failures／9 explicit skips**，seed471025：
AI89、Coding211、Protocol66、Agent683、Session168、Web149。后续hosted分页／SSE、
inbox upload与冷恢复进入同一Engine／Writer／hooks／MCP／Web回归。六项生产patch
保留#104/#105，另外三项保留#95/#99/#100，均不算能力通过；日志仍有故障注入与
teardown诊断，不推导#103并发cleanup已确认。109个测试源码hash和原dirty status
在运行前后相同，未发现测试cwd残留进程；原4580/PID815717未变。此批未重新运行
整个umbrella、远端CI、安装包、浏览器或在线模型；与此前范围重叠，不累加。

此前inbox／upload范围317 tests／0 failures／4 explicit skips（Protocol55、
Agent139、Session11、Web112）。三项raw patch依赖#104/#105，生产沙箱一项依赖#95。
2053卡分页、完整大reply、严格DTO、stale view、实际wire缩页、分支／restart／resync，
有界upload／原始TTL／cancel、active steering／idle commit、失败admission写盘／刷新
保留接受ACK通过。9个变更Elixir文件格式、dev/test warnings-as-errors与diff检查通过；
与旧范围重叠，不累加。

隔离4622独立WebSocket从真实native三题call上传90157-byte原文reply JSON；断线续传、
重复chunk、gap／conflict、cancel、stale leaf及精确commit通过，commit前无journal／
Provider effects。完整owned BEAM退出／新PID重启丢失buffer，重新上传复用consumed
receipt，不新增Provider：始终3次，log hash／mtime及journal原前缀保持，仅允许普通
model metadata。自有服务已停止，4580/PID815717未动；受控Provider，无新增browser／
在线模型／安装包／发布验收。

独立4621 WebSocket读全225张真实Writer卡片、校验72468-byte卡片完整hash，实际
reply consumed／dismiss／精确重试通过；完整owned BEAM退出／新PID恢复后卡片和
receipt相同，Provider仍1次且log hash／mtime未变，journal前缀相同，仅允许普通
model_change。服务已停止，4580/PID815717未动。本批未新增LiveView或在线Provider验收。

此前修正后的联合 scoped regression 覆盖29文件、436项测试，0失败、8明确跳过
（AI20、Protocol21、Agent175含6skip、Session103、Web117含2skip）。其中6项
生产raw patch验收因#104/#105保留原断言并跳过，其余为已有#95/#99；它们不算
能力通过。本轮没有重跑此前119文件全范围，两个范围重叠，不累加计数。
22个变更Elixir文件格式检查、dev/test warnings-as-errors与diff检查通过。

独立4619／4620的真实Engine／Runtime／Deno／HTTP与WebSocket验收覆盖active
steering、idle问题／notice回答、完整原文、精确重试、默认目录缺少apply_patch，
以及reasoning／search／message原生顺序和下一真实HTTP input完整重放。Chrome
实际发送后在idle提交中文／空白／换行回答，收到consumed，并关闭notice；两次
hosted回复显示原URL／title引用，opaque reasoning不进入正文，未知usage仍为unknown。
reload与完整BEAM退出／新PID启动后，Protocol resume／重试及两页reload均通过；
Provider8／HTTP2的hash与精确mtime未变，原journal前缀字节不变，只有Web会话各
追加一条普通model_change。两页最终LiveView connected，无横向溢出或console
warning/error；served app-4ec935d5.js与本地产物SHA256相同。临时服务及页面已关闭，
原4580/PID815717未动。Provider／HTTP为受控fixture，不推导在线商业模型或部署。

此前 Backplane 1.10.36 联合 scoped regression 覆盖 119 文件、1,379 项测试，
0 失败、3 明确跳过（AI83、Coding228、Protocol29、Agent674、Session213、
Web152）。此前 1,301 项的 seed 在 CodexResources 取消后的 cleanup 未确认处失败；
本次未触发，不撤销独立公开 API 复现或解除 #103。跳过为 #95 生产隔离、#99 中断 child 后直接完成 parent
和 #100 动态 child 委派，均保留实际 RED。dev/test warnings-as-errors 与
174 个相关 Elixir 文件格式检查通过；既有 JS syntax／asset build 证据对应此前
JS 源码，本批没有新增前端实现。
该结果替代早期重叠批次计数，不累加测试数，也不关闭下面的全局验收项。
Native root／child 投递定向18项通过，含两项先失败后通过的并发／落盘回归；
相关投递、ChildIO、ledger与callback identity 的7文件58项也通过，计数与联合范围重叠。
联合范围另含root／child MCP投递14项及Dispatcher执行错误回归，不重复累加。

独立 WebSocket 和 Chrome 在隔离 4613 服务完成默认 session.create、真实 PNG
模型／工具卡结果、root discovery 的 catalog revision 2、direct MCP 和真实
Deno nested 调用。reload 未改变 Provider/MCP 日志或图片／JSONL hash、size、
mtime，服务的 JS 字节匹配本地产物；LiveView connected，无横向溢出，最终
console 无 warning/error。Plan、Context/Skills、Memory 的独立客户端、reload
与完整隔离服务重启验收仍有效。

独立 4614/4615 的实际 Engine/Runtime/Deno/HTTP、WebSocket 与 Chrome 验收
覆盖 async active steering、idle 晚答、notice reply/dismiss、精确重试和原文传递；
cached native web_search 声明、完整 hosted metadata、原始 observation 与引用
均进入实际客户端。完整停止/启动 BEAM 后，原会话 resume 和两页 reload 保留
cards/citations，Provider9/HTTP1 计数与日志 hash 均未变化。修复前先复现 cold
Store 的 safe ETF 词汇加载失败及 async facts 的额外分支，修复后原场景通过。
此前 Provider active 时 reload 暂显示 interrupted 的限制已修复，并由隔离4618
验收：两条真实原生 Plan turn 的 running／completed reload 正确，SIGKILL 后新
BEAM 的 Protocol resume／Chrome reload 将未完成项恢复为 interrupted、完成项
保持 completed。Provider 四次与精确 log hash／mtime 不变，每会话仅一条 native
tool result；原始 journal 前缀字节不变，仅完成会话追加一条普通 model_change。
没有写入 interrupted terminal fact。两页最终 LiveView connected、无横向溢出或
console warning/error，served app JS SHA256 匹配本地产物；自有4618与两页已关闭，
原4580/PID815717未变。该回归与上述联合范围重叠，不重复计数。
自有 4611/4612/4613/4614/4615 服务均已停止，原 4580/PID815717 未重启；
这些验收使用受控 Provider，不推导在线模型或已部署状态。

本批 native async hook 另在独立 4616 完成默认 Protocol session.create、active
入队与消费分离、idle 等待下一真实 prompt、原始中文／空白和真实 UserPromptSubmit
仅执行三次的验收；Provider 共6次、真实 hook 命令2次。Chrome 显示两条反馈，完整
BEAM 停止／启动后的 Protocol resume／attach 与浏览器 reload 均无 work replay。
Provider／hook／submit 日志 hash 和精确 mtime 不变；原始40条 journal 字节不变，
Web 冷恢复另追加一条正常 model_change，不能称整个文件 hash 不变。Protocol
snapshot 仍按既有契约只带最后5条，messageCount12／messagesTruncated=true。
最终 LiveView connected、无横向溢出、console 无 warning/error，served app JS
SHA256 匹配本地产物。自有4616与临时浏览器页已关闭，原4580/PID815717保持。

MCP async hook 另在隔离4617完成默认Protocol创建、root发现后真实stdio MCP执行，
以及浏览器全新创建会话和实际发送。active入队与消费分开，idle原文进入下一真实
prompt首个Provider请求。恰逢terminal的admission保持delivery_unknown且不重投；
受控idle项只消费一次。完整BEAM停启后Protocol resume/attach和Chrome reload
保留反馈；两个会话的Provider/MCP/hook/submit日志hash不变（16/4/4/7次），
原始journal前缀字节不变，仅允许正常model_change metadata。最终LiveView
connected、console无warning/error；自有服务和页面已停止，4580/PID815717未动。

- [x] 本批39项功能scoped regression、dev/test warnings-as-errors、24文件格式与diff检查；全量剩余宿主另行验收。
- [x] 当前允许范围内剩余真实宿主路径：目录、执行、结果、跨turn、取消、关闭与恢复。
  逐family接入和独立客户端／包内证据见本文：1.10.51部分真实在线，1.10.52 Events／Goal，
  1.10.53完整42工具／三BEAM恢复、原立即Stop与dump／active-display修正。五项TODO、其他平台／环境、旧事实缺失及
  明确安全／权限排除保持独立未勾边界；不推导全量Codex或完整Writer在线兼容。
- [x] 本批Memory search／patch功能独立只读审查无可行动问题；#107已采用发布修复并通过消费者功能验收。
- [x] canonical Agent Note `5e9ffc9a-fbb2-49d4-942d-d935f4d4ef56`已更新至revision70，
  完整内容精确回读，2373字符旧工具删除清单和title／labels／attachments保持相同。
  在原工程说明内整合正式1.10.44及13项lock范围、逐组件close与guardian构建、
  原调用等待实际Settings／Protocol安装／完整完成事实、host显式reconcile与原失败不变、
  实际child默认stdio helper崩溃的原始unconfirmed报告与独立root继续、
  root资源精确取消／child #131、Store交接与Goal记账后两BEAM归档续接、Error #126
  和idle restored child transfer #133。保留此前完整MCP／独立客户端／恢复历史证据；
  补入原生安装完成新结果的实际Chrome／Protocol／冷BEAM验收，10／4调用和9份文件不变。
  补入本机Linux生产归档／installed插件组件、实际包内guardian调用／确认关闭与代码路径证据。
  最新59项功能为54通过／5项上游失败，独立BEAM／公开trace与本机组件验收分开；
  完整native profile的installed验收、其他平台／CI／在线模型未完成。
  五项用户TODO排除本阶段完成门。该revision70记录1.10.44时的#127／#128边界；下述1.10.45
  接入另有当前功能验证，不能把旧客户端／安装包证据改称新版本验收。

- [x] 正式1.10.45联合功能验收：12个纯功能文件80项，75通过／5上游失败（seed43153）；
  #131三项、#126一项、#133一项保留原断言。新增Goal exact Task／actual DOWN／gate／
  cancel与supersede／写失败只补存／已seal后不重写取消原因、排队timer保留原错误、
  旧Goal只读兼容／exact retry／fork、实际Engine新自动run及Readiness direct／真实Deno／
  完整paired JSONL均通过。fixture teardown以精确monitor／DOWN修正alive?/stop竞态，
  原cleanup故障断言不变。dev/test严格编译、16文件格式、五项lock和diff检查通过；
  662文件基线只有19个授权既有文件变化、新增两功能测试，其余643完全一致。
- [x] 实际Agent下一次输入与显式Goal set／clear／fork接入窄范围结算准备：
  复用host先在supervised inspection Task仅重试已sealed的no-start持久化；
  存储仍失败时返回原cause，不写新canonical user、不建新host binding／Runtime或Provider。
  修复后同一Goal／thread可继续；source保存原receipt，fork使用公开独立空admission账本。
  其他indexed-run／unknown恢复错误保持阻塞，真实host退役流程继续独立执行。
  新增五项纯功能回归通过，普通写错误注入，不做安全／权限／沙箱测试。
- [x] 此前admission源码八文件44项定向功能通过（seed43155）；扩展十文件65项有16失败。
  用本轮修改前三份源码重跑两个受影响文件，21项复现完全相同的16个失败名称，
  随后精确恢复当前源码并重新验证44项。dev/test严格编译与四文件格式通过；
  664文件基线只改七个既有文件、新增一项功能文件，其余657完全相同。
- [x] live manager分阶段收尾已接入：两个close入口都先单独提交execution确认，
  close_execution保留manager／Session／Registry／CodexResources／LifetimeRecovery；
  RootRetirement再写独立hooks／SessionEnd，Goal原receipt投递／Store ACK后，full close
  刷新child→manager→root Session公开ACK，再export并退役保留owner。归档失败保留原Error，
  不改写真实execution确认；generation-correlated阶段ACK保留已完成archive／Session-stop，
  后续错误只重试剩余收尾。两个generation替换入口都需完整关闭。
- [x] 显式退役与operation release异步完成full gate，失败保留原host／cause，不能直接adopt；
  rename／adopt／delete在Goal仍存活时完成child记账后才退役Goal／Store及移动文件。
  root-only retirement保持既有opening／admission恢复边界；无Conversation的Goal准备失败
  仍完整关闭reserved Session，不因分阶段而保留无用途owner。orderly shutdown在原owner
  存活时尝试live gate；active／unconfirmed关闭仍保留真实错误。
- [x] 前一阶段Goal／root九文件51项通过（seed43156），四项新阶段边界通过，含并发读取
  execution确认、Goal写故障精确补记、operation reopen与实际failed-child Runtime rename。
  dev/test warnings-as-errors、六文件格式与diff检查通过；本批无lock或依赖源码变更。
- 1.10.45历史记录：完整child／archive扩展三文件30项曾有18失败，此前16个失败名称全部保留，
  另含新完整live-flow和原普通Error archive。11项仍先full-close未清Goal outbox，
  六项到达archive restore后的root结束断言，一项为#126；新阶段通过不等于这些流程通过。
  公开trace证明restore成功、Registry transfer=:ok，随后#133的transfer_ready／prepare_detach拒绝。
  当前1.10.48消费者结果见文首；本段保留当时的复现，不作为当前开放失败清单。
  相邻command／environment／PluginRuntime13项当时有1项独立fixture的on_exit stop/shutdown竞态失败；
  相关fixture与PluginRuntime未改，未扩修或弱化断言。所有选择有重叠，不累计通过数。
- [x] Web／Protocol detached-child Stop改用close_execution，等待真实执行退役并保留
  manager／Session／Registry／资源／恢复owner。execution_result保存真实失败及原始写cause，
  修复后可重试；不提前确认root hooks／SessionEnd或archive。完整退役／文件操作继续走full gate，
  无live Agent的Runtime.close_subagents fallback保持full-close。
- [x] SessionLive按实际取消结果投影：cancelled_children保留root完成态，already_cancelled
  为cancelled，仍在取消才显示cancelling；真实错误显示既有公共信息且保留原phase。
  两项真实Runtime Web回归在修复前复现假cancelling，修复后通过。
- [x] 当前十二文件63项Goal／root／Provider／environment／command功能通过（seed43157）；
  集成选择执行六项lifetime阶段／取消用例及两项Web用例（lifetime共发现23项、排除17项）。
  真实Provider退出、保留owner、无新增效果、普通写故障cause及修复／后续full close均通过。
  扩展child／lifetime／archive32项仍为完全相同18个失败名称，未增加或消失，原断言不变。
- [x] 独立4685真实WebSocket／Chrome新会话→Send→Stop subagents验收通过，覆盖Completed
  投影和实际退役文件写故障／公共错误／修复。四个session共12次受控Provider调用及12条精确DOWN，
  两次完整自有BEAM替换后Protocol读取／resume与页面reload无新增调用；第二次cold read十个
  journal／log字节及mtime完全不变，served asset匹配本地。自有服务和两页已关闭，原4580未动。
  证据/tmp/sigma-cancel-stages45-vvuyjawz；不声称在线模型、installed-release、部署或
  #133／#134未通过路径验收。与前述测试范围重叠，不累计总数。
- [x] #134正式公开契约与消费者已接入：orderly shutdown先保全stage，冷ACK后离线complete，
  当前验收见文首。原1.10.45等待契约的记录属于历史；无stage的突退出仍不恢复。
- [x] 剩余18项只读归属审计：11个direct-full-close是archive／Goal ACK顺序冲突，
  原cold用例要求shutdown后再补记，不能改成live ACK替代；该承诺需要#134。
  六个root完成失败中一项有精确#133公开trace，另五项路径一致但未逐项隔离，
  不能仅凭cancelled／unknown输出把它们全部断言为#133；普通Error归档一项是#126。
  未建立这18项中另一个可独立修复的Sigma生产缺陷，保留所有完整原断言。
- [x] 当前插件取消批次新增两个真实Engine direct／Deno完整回归；定向两项均在新prompt失败，
  独立公开trace复现同样结果。plugin23／PluginRuntime7／Protocol4／Web5共39项：
  36通过，新增两项#135与原一项#133失败；无新增安全／权限／沙箱实现或测试。
  证据/tmp/sigma-plugin-cancel45-ym_qciva；本批无新浏览器、在线模型、installed-release验收。
- [x] 本批dev/test严格编译、两个变更Elixir／test文件显式format check与diff检查通过；
  666文件基线仅六个授权既有文件变化，其余660相同，无新仓库文件或lock／依赖修改。
- [x] 当前dev/test warnings-as-errors、五个变更Elixir／test文件显式format check及diff检查通过；
  665文件基线仅八个授权既有文件变化、新增session_cancel_functional_test.exs，
  其余657完全相同，mix.lock未变。最终21:33 Asia/Shanghai查询Hex仍为1.10.45，
  #126／#131／#133／#134仍open，无依赖更新。
- [x] canonical Agent Note `5e9ffc9a-fbb2-49d4-942d-d935f4d4ef56`更新至revision76并精确回读；
  原2373字符旧工具移除清单、title／labels／attachments保持相同，在同一工程说明内整合
  1.10.45架构、admission与分阶段收尾、detached Stop／实际写故障／Web投影和当前客户端／
  两次cold-BEAM读取验收，保留完整流程18失败与#134离线归档契约边界，
  并整合真实插件取消／晚到安装与fresh-binding失败、公开tool义务及#135的解除条件；
  保留#126／#131／#133及1.10.44客户端／生产包版本范围。

未选择的V1 collaboration、test-only条目及兼容别名不自动扩大默认集合。
当前正式五包为1.10.53；#147已正式发布、采用并通过原立即Stop完整回归，#148已解除。
原#126／#131／#133／#134／#135、#139–#142、#144／#145及#146均有各自消费者结果。
当前tool48＋Operations4＋Web3在最终独立解压包55项通过，独立BEAM冷读53文件全保持；
实际Protocol／Chrome原取消续接、完整dump、正确基线冷恢复与新active reload验收完成。
以前1.10.44／45的失败及open状态、52注册前窗口失败和发布故障均属历史，保留原版本。
完整42工具在当前1.10.53生产包的三独立BEAM验收已通过；真实在线仍限1.10.51无Writer
profile，不改称完整53在线验收，不累计重叠批次为唯一总数。

剩余适用边界：旧child安装后首次新增tool_search超过原目录上限（权限范围排除），
其他平台／环境、没有有效export stage的突退出、缺失legacy事实及其他未结算work。
完整close／文件操作／新准入须真实完整completion；helper崩溃保留actual unconfirmed。
board原raw argument envelope仍缺，按已接受安全／权限排除范围保留，不新增相关开发或测试。

web::run／image_gen::imagegen实际backend、实际registry选择、remote encrypted History和
notes.thread_hint五项由用户明确暂缓，不作本阶段完成门。当前允许范围的Goal验收已完成；
这些TODO及其他平台／完整Writer在线限制继续明确保留。1.10.53采用批次的10个变更Elixir／
test／manifest文件format和git diff检查通过；其675份原文件仅15份授权路径变化，其他660份
保持、无删除。本次完整42工具验收不改产品源码／测试／依赖，当前675份基线仅四份工程文档
变化、671份保持，无新增／删除；diff检查通过。没有自动commit／push、发布、部署，
自有测试服务和页面已关闭，原4580未启动或重启。
