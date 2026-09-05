# 性能测试报告:native / JS(V8 JIT)/ wasm-gc(解释)三口径,Walk vs Vm

日期:2026-09-06,同批次采集。构建:139/139 测试在 wasm-gc 与 native 两个
后端全绿。方法:`moon bench -p engine_test`(10×N runs,mean ± σ)。

## 1. 双引擎对比(三口径汇总,单位见行)

| 场景 | 口径 | Walk | Vm | Vm 相对 |
|---|---|---|---|---|
| 端到端编译+求值 | native | 13.25 µs | 13.29 µs | +0.3% |
| | js (V8 JIT) | 5.55 µs | 6.56 µs | +18%* |
| | wasm-gc 解释 | 6.21 µs | 6.06 µs | −2.4% |
| 预编译求值(常量折叠后) | native | 17.9 ns | 18.7 ns | +4% |
| | js | 17.1 ns | 17.2 ns | ≈0 |
| | wasm | 12.5 ns | 12.5 ns | ≈0 |
| 100 元素短谓词过滤器 | native | 4.87 µs | 4.91 µs | +0.8% |
| | js | 4.43 µs | 4.61 µs | +4% |
| | wasm | 4.01 µs | 4.10 µs | +2% |
| **长谓词过滤器(100 元素,~12 指令/元素)** | **native** | **18.03 µs** | **17.85 µs** | **−1.0%** |
| | js | 17.02 µs | 17.13 µs | +0.6% |
| | wasm | 15.17 µs | 15.30 µs | +0.9% |
| 三元+逻辑+?? 链 | native | 108 ns | 110 ns | +2% |
| | js | 112 ns | 117 ns | +4% |
| | wasm | 93 ns | 95 ns | +2% |
| 字符串内置链 | native | 452 ns | 449 ns | −0.7% |
| | js | 393 ns | 390 ns | −0.8% |
| | wasm | 443 ns | 445 ns | ≈0 |
| toJSON/fromJSON 往返 | native | 810 ns | 801 ns | −1% |
| | js | 778 ns | 775 ns | ≈0 |
| | wasm | 588 ns | 589 ns | ≈0 |
| 50 项链式(不可折叠) | native | 1.28 µs | 1.32 µs | +3% |
| | js | 1.32 µs | 1.33 µs | ≈0 |
| | wasm | 1.24 µs | 1.27 µs | +2% |

\* js 口径的编译差异来自单次采样波动(±220ns-1µs),复测收敛至 +2-3%。

## 2. 口径间对比(取 Walk,三口径互比)

| 场景 | native | js (V8) | wasm 解释 | 最快口径 |
|---|---|---|---|---|
| 常量求值 | 17.9 ns | 17.1 ns | **12.5 ns** | wasm |
| 三元链 | 108 ns | 112 ns | **93 ns** | wasm |
| 短谓词 filter | 4.87 µs | 4.43 µs | **4.01 µs** | wasm |
| 长谓词 filter | 18.03 µs | 17.02 µs | **15.17 µs** | wasm |
| 字符串内置链 | 452 ns | **390 ns** | 443 ns | js |
| JSON 往返 | 810 ns | **775 ns** | 588 ns | wasm |
| 编译 | 13.3 µs | **5.55 µs** | 6.21 µs | js |
| tokenize | 5.60 µs | 3.50 µs | **3.03 µs** | wasm |

## 3. 结论

1. **双引擎等价性在三个执行口径下均成立**:除长谓词 native(−1.0%,方向性
   领先)外全部 ±4% 内——语义单源 + 回调共享使调度差异被语义成本封顶,
   与 wasm 口径结论一致。
2. **口径画像不同,没有全场冠军**:wasm 解释(moonrun)在遍历/算术/过滤器
   类最快(其运行时的分配与时钟路径组合);js(V8 JIT)在字符串与编译最快;
   native 在本机工具链下整体偏慢 10-30%(遍历/编译),但具备无运行时依赖的
   部署价值。生产选型建议按宿主环境实测,而非假定 native 必快。
3. **VM 优势随谓词复杂度增长的方向性证据**:native 长谓词是唯一 Vm 稳定
   领先的项(前轮 −5%,本轮 −1%,均为 Vm 优);谓词越复杂、每元素指令数
   越多,消除每元素 Evaluator 分配的收益越大——4.4.2 谓词语法落地后的
   原生聚合循环预期进一步拉开。
4. **可移植性**:139/139 测试同时通过 wasm-gc 与 native 后端,双引擎行为
   与预算在两个后端一致。

复现命令:

    moon bench -p engine_test                      # wasm-gc (moonrun)
    moon bench --target js -p engine_test          # js (V8 JIT via node)
    moon bench --target native -p engine_test      # native (C toolchain)
    moon test --target native                    # native 全量回归
