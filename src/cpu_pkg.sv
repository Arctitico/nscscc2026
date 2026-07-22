// ============================================================================
// cpu_pkg.sv —— 级间总线与公共类型定义
//
// 本文件集中定义 9 级流水线（IF ID RR DP IS RF EX WB CM）各级之间传递的
// packed struct 总线。新增字段时改这里并同步上下游模块。
//
// 当前为「顺序双发射」：每级承载一个 2 槽 bundle，slot0 程序序在前，
// slot1 在后，并始终保持 v1 => v0。XX_to_YY_valid 表示 slot0/整组有效，
// slot1 的有效性由 bundle 中的 v1 携带。RR / DP 仍是直通缓冲，IS 负责保守的
// co-issue/拆分；未来乱序化时再扩展重命名 tag 和发射队列信息。
// ============================================================================

package cpu_pkg;

// ---------------------------------------------------------------------------
// alu_op 编码（12 位 one-hot），必须与 alu.sv 中的 OP_* 常量一致：
//   bit0 add  bit1 sub  bit2 slt  bit3 sltu  bit4 and  bit5 nor
//   bit6 or   bit7 xor  bit8 sll  bit9 srl   bit10 sra bit11 lui
// 2026 baseline 使用 add/sub/slt/and/or/xor/sll/srl/lui；mul.w 与 cpucfg
// 在 EX 中选择专用结果，不占用 alu_op 位。
// pcaddu12i 复用 add（src1_is_pc=1），无需单独 alu_op。
// ---------------------------------------------------------------------------

// 译码结果总线（decoder 输出）
typedef struct packed {
    logic [31:0] imm;          // 立即数（已按指令做符号/零扩展、移位）
    logic [11:0] alu_op;       // 12 位 one-hot
    logic [ 4:0] rd;           // inst[4:0]，第二源（st/beq/bne）或目的寄存器
    logic [ 4:0] rj;           // inst[9:5]，第一源寄存器
    logic [ 4:0] rk;           // inst[14:10]，第二源寄存器（R 型）
    logic [ 4:0] rf_waddr;     // 写回目的寄存器号（bl 为 r1，其余为 rd）
    logic [ 1:0] rf_wdata_sel; // 00=alu_result 01=load_data 10=pc+4
    logic        rf_we;        // 是否写寄存器堆
    logic        src1_is_pc;   // alu_src1 取 pc（bl / pcaddu12i）
    logic        src2_is_imm;  // alu_src2 取 imm
    logic        src_reg_is_rd;// 第二个读端口取 rd（st / beq / bne），否则取 rk
    logic        need_rj;      // 真正读 rj（用于前递/停顿判定，避免误停）
    logic        need_rkd;     // 真正读第二寄存器（rk 或 rd）
    logic        is_mul;       // mul.w，EX 选择乘法器低 32 位
    logic        is_cpucfg;    // cpucfg，EX 按 rj 值读取配置字
    // 访存
    logic        is_ld;        // 加载
    logic        is_st;        // 存储
    logic        is_st_b;      // 字节存储（st.b），决定字节写使能
    logic [ 3:0] ld_width;     // 1111=字 0001=字节（加载位宽）
    logic        ld_ext_signed;// 加载符号扩展（ld.b 为有符号）
    // 分支
    logic        is_branch;    // b/bl/jirl/beq/bne 任一
    logic        inst_jirl;    // jirl：目标 = rj + imm
    logic        inst_beq;     // beq：相等跳转
    logic        inst_bne;     // bne：不等跳转
} d_bus_t;

// ===================== 单槽内容 =====================
// bp_taken/bp_target：IF 取本指令时的预测，沿流水带到 EX 比对。
typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;
    logic        bp_taken;     // 预测是否跳转
    logic [31:0] bp_target;    // 预测目标（bp_taken=1 时有效）
} if_slot_t;

typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;         // 提交调试口需要沿流水保存原始指令
    d_bus_t      d_bus;
    logic        bp_taken;
    logic [31:0] bp_target;
} id_slot_t;

typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;
    logic [31:0] imm;
    logic [11:0] alu_op;
    logic [31:0] alu_src1;     // src1_is_pc ? pc : 前递后的 rj
    logic [31:0] alu_src2;     // src2_is_imm ? imm : 前递后的 rk/rd
    // 乘法器专用操作数不含 EX 当拍旁路，物理切断 ALU->DSP 长路径。
    logic [31:0] mul_src1;
    logic [31:0] mul_src2;
    logic [31:0] rkd_value;    // 前递后的第二寄存器值（store 数据 / 分支比较）
    logic        is_mul;
    logic        is_cpucfg;
    // 分支
    logic        is_branch;
    logic        inst_jirl;
    logic        inst_beq;
    logic        inst_bne;
    logic        bp_taken;     // 取指时的预测方向（EX 比对误预测）
    logic [31:0] bp_target;    // 取指时的预测目标
    // 访存
    logic        is_ld;
    logic        is_st;
    logic        is_st_b;
    logic [ 3:0] ld_width;
    logic        ld_ext_signed;
    // 写回
    logic [ 1:0] rf_wdata_sel;
    logic        rf_we;
    logic [ 4:0] rf_waddr;
} rf_ex_slot_t;

typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;
    logic [31:0] alu_result;   // 计算结果，加载/存储时为访存地址
    logic        is_mem;       // 请求已被 Cache 接受，WB 等待 data_ok
    logic [ 1:0] addr_lo;      // 访存地址低 2 位（字节/半字选择）
    logic [ 3:0] ld_width;
    logic        ld_ext_signed;
    logic [ 1:0] rf_wdata_sel;
    logic        rf_we;
    logic [ 4:0] rf_waddr;
} ex_wb_slot_t;

typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;
    logic [31:0] rf_wdata;
    logic        rf_we;
    logic [ 4:0] rf_waddr;
} wb_cm_slot_t;

// ===================== 成对级间总线 =====================
typedef struct packed {
    if_slot_t s0;
    if_slot_t s1;
    logic     v1;
} if_to_id_bus_t;

typedef struct packed {
    id_slot_t s0;
    id_slot_t s1;
    logic     v1;
} id_to_rr_bus_t;

typedef struct packed {
    id_to_rr_bus_t id_to_rr_bus;
} rr_to_dp_bus_t;

typedef struct packed {
    rr_to_dp_bus_t rr_to_dp_bus;
} dp_to_is_bus_t;

typedef struct packed {
    dp_to_is_bus_t dp_to_is_bus;
} is_to_rf_bus_t;

typedef struct packed {
    rf_ex_slot_t s0;
    rf_ex_slot_t s1;
    logic        v1;
} rf_to_ex_bus_t;

typedef struct packed {
    ex_wb_slot_t s0;
    ex_wb_slot_t s1;
    logic        v1;
} ex_to_wb_bus_t;

typedef struct packed {
    wb_cm_slot_t s0;
    wb_cm_slot_t s1;
    logic        v1;
} wb_to_cm_bus_t;

// 每个槽各自向 RF 广播一份前递信息。年轻槽优先级高于年长槽。
// EX 的数据对加载指令无效；WB 等待 data_ok 时，加载数据同样无效。
// 两级都用 is_ld 标记未就绪的 load，供 RF 触发 load-use 停顿。
typedef struct packed {
    logic        valid;
    logic        rf_we;
    logic        is_ld;        // EX/WB 可置 1；CM 恒 0
    logic [ 4:0] rf_waddr;
    logic [31:0] rf_wdata;
} fwd_bus_t;

endpackage
