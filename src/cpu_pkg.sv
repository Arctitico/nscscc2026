// ============================================================================
// cpu_pkg.sv —— 级间总线与公共类型定义
//
// 本文件集中定义 9 级流水线（IF ID RR DP IS RF EX WB CM）各级之间传递的
// packed struct 总线。新增字段时改这里并同步上下游模块。
//
// 当前为「顺序单发射 baseline」：
//   - RR / DP / IS 三级目前是「直通」缓冲级，其总线 struct 只裹一层上一级
//     的总线（rr_to_dp_bus_t 内含 id_to_rr_bus_t ...）。实现乱序双发射时再在
//     这些 struct 里扩展重命名 tag / 发射信息，**不要当作冗余去化简掉**。
//   - regfile.sv 的 4 读 2 写端口也是为双发射保留，baseline 只用 1 读对 + 1 写。
// ============================================================================

// ---------------------------------------------------------------------------
// alu_op 编码（12 位 one-hot），必须与 alu.sv 中的 OP_* 常量一致：
//   bit0 add  bit1 sub  bit2 slt  bit3 sltu  bit4 and  bit5 nor
//   bit6 or   bit7 xor  bit8 sll  bit9 srl   bit10 sra bit11 lui
// C3 21 条指令只用到 add/sub/and/or/xor/sll/srl/lui，其余位保留。
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

// IF -> ID
typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;
} if_to_id_bus_t;

// ID -> RR
typedef struct packed {
    logic [31:0] pc;
    d_bus_t      d_bus;
} id_to_rr_bus_t;

// RR -> DP（直通：裹一层 id_to_rr_bus_t，乱序时扩展重命名信息）
typedef struct packed {
    id_to_rr_bus_t id_to_rr_bus;
} rr_to_dp_bus_t;

// DP -> IS（直通）
typedef struct packed {
    rr_to_dp_bus_t rr_to_dp_bus;
} dp_to_is_bus_t;

// IS -> RF（直通）
typedef struct packed {
    dp_to_is_bus_t dp_to_is_bus;
} is_to_rf_bus_t;

// RF -> EX：已完成寄存器读 + 前递 + 源操作数选择
typedef struct packed {
    logic [31:0] pc;
    logic [31:0] imm;
    logic [11:0] alu_op;
    logic [31:0] alu_src1;     // src1_is_pc ? pc : 前递后的 rj
    logic [31:0] alu_src2;     // src2_is_imm ? imm : 前递后的 rk/rd
    logic [31:0] rkd_value;    // 前递后的第二寄存器值（store 数据 / 分支比较）
    // 分支
    logic        is_branch;
    logic        inst_jirl;
    logic        inst_beq;
    logic        inst_bne;
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
} rf_to_ex_bus_t;

// EX -> WB：ALU 结果 + 原始访存读数据 + 写回控制
typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;   // 计算结果，加载/存储时为访存地址
    logic [31:0] mem_rdata;    // 原始 data_sram_rdata（组合读，EX 周期锁存）
    logic [ 1:0] addr_lo;      // 访存地址低 2 位（字节/半字选择）
    logic [ 3:0] ld_width;
    logic        ld_ext_signed;
    logic [ 1:0] rf_wdata_sel;
    logic        rf_we;
    logic [ 4:0] rf_waddr;
} ex_to_wb_bus_t;

// WB -> CM：最终写回数据
typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rf_wdata;
    logic        rf_we;
    logic [ 4:0] rf_waddr;
} wb_to_cm_bus_t;

// 前递总线：EX / WB / CM 各自向 RF 广播 {有效, 写使能, 写号, 写数据}
// EX 的数据对加载指令无效（数据尚在访存通路上），用 is_ld 标记触发 load-use 停顿。
typedef struct packed {
    logic        valid;
    logic        rf_we;
    logic        is_ld;        // 仅 EX 用；WB/CM 恒 0
    logic [ 4:0] rf_waddr;
    logic [31:0] rf_wdata;
} fwd_bus_t;
