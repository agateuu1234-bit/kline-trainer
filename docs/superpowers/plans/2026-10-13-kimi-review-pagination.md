---
phase_delivery: true
---

# Kimi 完整审查输入修复

用户已授权将本治理修复从 Codex/Claude 兼容层工作中分离；本分支基于 origin/main。

## 问题与设计

实际 Kimi Read 调用反复遗漏可选分页参数，超过默认读取范围的完整 diff 未被读完。
单独的 approve 文本不能证明完整输入已提供给审查者。

包装器将冻结的完整 diff 按最多 200 行、64 KiB 分块，生成含原始摘要、字节数、
行号范围和每块摘要的 manifest。提示词要求先读取 manifest，再逐一读取所有分块，
每次只需提供 path。分块拼接必须逐字节等于原始 diff。

写 ledger 前重新校验输入，并匹配真实 Read 调用 ID 与工具返回：manifest 和每块
都必须在最终结论前获得完整、无错误且内容一致的返回。缺失、截断、伪装、重复 ID、
输入被修改均拒绝写入。原有冻结快照、模型固定、只读工具、引用漂移检查及 ledger
指纹算法保持原行为。此检查证明内容已送达工具流，不能证明模型理解了全部内容。

不支持的编码、超过 Read 单行限制的输入，以及无法装入有界 manifest 的超大 diff
明确失败，不缩减审查范围。临时文件权限不是抵御同用户恶意进程的安全边界。

## 实施与验证

1. 使用真实包装器、临时 Git 仓库和模拟外部 reviewer，复现仅 approve 仍写 ledger。
2. 实现有界输入和工具流覆盖检查；验证漏读、截断、错误、篡改均拒绝。
3. 验证完整输入成功写入原始分支指纹，覆盖 Unicode 和无末尾换行。
4. 运行现有 hook 测试，区分已有失败与新增回归；完成独立审查后进入 PR 流程。

已观察到两个红灯：旧包装器允许无读取 approve；初版覆盖检查接受带错误标记的返回。
修复后专项测试覆盖普通及非 UTF-8 stderr 诊断行、伪造 stderr 事件和工作区模式
输入清理，共 23 项。
整体 hook 首轮为 230 passed、7 failed，失败项与此前基线一致。
真实 reviewer 首轮读取了 3 个分块，但返回 needs-attention，未写凭证；尚不宣称
真实批准链路恢复。

### 第一轮审查反馈核实

- 混合日志解析：成立。先用 stderr 普通文本测试复现 exit 23，再允许非对象诊断行；
  JSON 对象事件仍严格解析，工具结果必须完整匹配。
- 工具内容格式：实际 CLI 0.36.1 诊断流已核实，tool 对象只有 role、tool_call_id、
  content，content 为裸编号行字符串，界面状态尾注不在该字符串内。诊断输入为
  `fixture-line-0001` 至 `fixture-line-1000`，内容严格等于
  `"\n".join(f"{i}\tfixture-line-{i:04d}" for i in range(1,1001))`。
  本地诊断流 `/tmp/kline-kimi-pagination-diagnostic-stream.jsonl` 的 SHA256 为
  `92d8ddce8a53ae63c7b007951b0442a97d674d2bc38d7cf4d7bb3b66845afa13`；
  content SHA256 为 `915e62d4b0f6f03057fb9c7d1bb94a616ae406b12181bcb23caa8da3097d3609`。
  此证据支持当前格式，未来 CLI 改变格式会拒绝签发，不作自动兼容推断。
- 分行语义：第二轮后统一显式使用 `data.split(b"\n")`，重添被分隔的 LF，
  与行号计算采用完全相同的边界。实现不再依赖 splitlines API 的隐式规则。

第二轮真实流中 manifest.json、part-0001.diff、part-0002.diff、part-0003.diff
的 tool content 均与本地预期编号内容严格相等，覆盖格式已实际验证。
第二轮仍为 needs-attention（仅分行说明争议），未写入凭证。

### 第三轮及待办

第三轮仍为 needs-attention，达到本轮三次审查上限。清理脚本测试遗漏新 helper 的
反馈成立：先运行 `bash tools/test-attest-exit-codes.sh` 复现 7/8 失败，再同步提取
真实 `_cleanup_input`，补充输入目录清理断言。修复后 Kimi 10/10、Codex 8/8 通过。

剩余审查意见：尚缺真实 approve→verify→ledger 端到端成功；有界输入拒绝 CR、
超长行和超大 manifest 的可用性限制。前者确实尚未完成，后者是已披露的保守设计，
不以跳过覆盖校验解决。第三轮后的测试修复尚未独立复审，需获准新审查周期后继续。

### 用户授权的新审查周期

用户已批准继续。新周期第一轮确认清理测试修复，未发现核心覆盖机制绕过点；
结论仍为 needs-attention，提出输入上限、日志编码、工作区模式清理测试及真实
校验成功证据。工作区模式的真实包装器测试确认退出 20、无凭证、输入目录已清理。
非 UTF-8 普通 stderr 行测试先复现 exit 23，再改为按字节识别 JSON 对象行，
仅对对象行严格解码解析；不对工具内容做有损解码或放宽全等校验。

本轮运行期间，使用原样保存的真实 stream、完整重组 diff 和实际临时 coverage.py
执行 `verify`，退出码为 0，stderr 为空。流 SHA256：
`b215ae8c77ed43170de91b560c1885fd8f8cef94c4e290e889924b7dda5098e2`。
原始文件保存于本机 `/tmp/kimi-pagination-cycle2-evidence/real-stream.jsonl`，
diff 保存于同目录 `original.diff`。未伪造或替换 verdict，未写 ledger。
这直接验证了真实工具流能通过实际校验器；最终 approve→ledger 仍待独立批准。

输入上限是本修复明确保留的范围限制：超限必须拒绝，不发放未经完整读取的凭证。
任意规模输入的多层清单及编码转换属于后续设计，本分支不加入人工绕过。

新周期第二轮发现 stderr 中可出现由工具参数构造的伪造 JSON 事件。使用测试桩
将全部假 Read 调用及结果写到 stderr、仅将最终 approve 写 stdout，成功复现旧版
错误签发。修复后 stdout 独立保存供判决与覆盖检查；stderr 独立保存于临时输入
目录，仅作诊断展示，绝不进入事件解析。23 项测试包含该注入反例。非 UTF-8 日志
只在展示时替换非法字节，正式工具流继续严格解析。stderr 随输入目录一起清理。

## 验收（非开发者）

| 操作 action | 预期 expected | 判定 pass_fail |
| --- | --- | --- |
| 在本分支目录终端粘贴 `python3 -m pytest tests/hooks/test_kimi_review_coverage.py -q` | 末行显示 `23 passed` | 全部通过为通过；任一 failed/error 为失败 |
| 查看上述测试名称和输出中的漏读、错误、篡改案例 | 每个案例通过，表示包装器拒绝写入凭证 | 任一反例仍能写入凭证为失败 |
| 查看完整读取测试输出 | 完整输入可写凭证，摘要与原始 diff 一致 | 成功案例失败或摘要不同为失败 |
| 查看独立审查记录及 PR 检查 | 完整读取证据及批准针对最终提交，必需检查通过 | 缺少任一证据时不得视为可合并 |
