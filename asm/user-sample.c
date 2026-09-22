typedef unsigned int u32;

#define ARRAY_BEGIN  0x1c200000u
#define ARRAY_END    0x1c400000u
#define RESULT_ADDR  0x1c400000u

void _start(void)
{
    volatile u32 *p =
        (volatile u32 *)ARRAY_BEGIN;
    volatile u32 *const end =
        (volatile u32 *)ARRAY_END;
    volatile int *res_p = 
        (volatile u32 *)RESULT_ADDR;

    while (p != end) {
        u32 lhs;
        u32 rhs;
        int result;
        int masked;
        int flag;

        lhs = *p;
        p++;
        rhs = *p;
        p++;

        result = 0;
        masked = lhs ^ rhs;

        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);
        masked = masked >> 1;
        flag = masked & 0x00000001;
        result = result - flag;
        result = result + (flag == 0);

        *res_p = result;
        res_p++;
    }
    
    return;
}
/*
loongarch32r-linux-gnusf-gcc -S -O2 \
-march=loongarch32r -mabi=ilp32s -msoft-float -mstrict-align \
-ffreestanding -fno-builtin -fno-stack-protector -fno-pic \
-mno-cond-move-int -mno-check-zero-division \
-fno-jump-tables -fno-tree-switch-conversion \
-fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident \
user-sample.c -o user-sample.s
*/