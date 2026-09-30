## 关于本仓库
本仓库是我在第十届龙芯杯个人赛 la 赛道的参赛作品，二等奖 顺序双发射 9级流水线 120MHz

本仓库里的源码 99% 由 codex 生成（）我主要分享一些参赛经验：

## 参赛经验
### 1
建议自己弄一些随机测试，尤其是有任何乱序的处理器。今年有一个神秘的 alpha 测试，把四个测例微调了一下，对乱序选手的影响较大。群里有参赛选手因为 alpha 测试中有测例不通过，乱序多发设计仅获得了三等奖；当然，也有选手四个alpha测例通过三个，拿到一等奖。

### 2
也许不需要 dcache，因为 sram 访存真的很快。如果一定要实现 dcache 的话，考虑实现 data prefetcher.

### 3
[今年的测试集](https://github.com/Arctitico/nscscc2026/blob/inorder-int-no-div/doc/perf_tests_asm.md)的情况下，乱序多发收益并不明显

### 4
2027 听说要改革测试集，不要照着往年题目过度优化

### 5
建议在实现代码之前(让AI)学习一下开源项目的代码，比如：[ibex](https://github.com/lowRISC/ibex), [cva6](https://github.com/openhwfoundation/cva6)

### 6
关于分支预测：从今年[性能测例](doc/perf_tests_asm.md)的情况来看，理论上 BTFNT 的分支预测器就足够了，与两位饱和计数器效果应该是非常接近的。不过我没验证。

### 7
关于决赛的现场赛：**断网**，**禁止使用本地LLM**，要求参赛选手搓一个 .s 并提交。可以修改 RTL 设计。

 - 当然可以手搓 .s ，但是也可以先写一个 .c ，然后用编译器生成 .s 。不过需要你的处理器设计支持编译器生成的指令才行
 - 算法设计很重要。今年的赛题在使用了 popcount 的情况下可以达到两位数ms，使用最朴素的模拟的算法可以达到三位数ms
 - 适当的循环展开收益会非常明显，如果你的算法适合循环展开的话。
 - 可以看一下[往年赛题](https://github.com/Arctitico/nscscc2026/blob/inorder-int-no-div/doc/赛题)，一般不会出现除法

[我当时的源码](https://github.com/Arctitico/nscscc2026/blob/inorder-int-no-div/asm)使用最朴素的算法写了个 .c ，然后直接用编译器得到的 .s，最终是 220 ms。有选手使用 popcount ，最终是 46 ms，差距还是很大的