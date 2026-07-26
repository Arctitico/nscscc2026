# 性能测例汇编源码

## UTEST_STREAM

```asm
UTEST_STREAM:
    li.w        a0,0x1c100000
    li.w        a1,0x1c400000
    li.w        a2,0x00300000
    add.w       a2,a0,a2
stream_next:
    ld.w        t0,a0,0x0
    st.w        t0,a1,0x0
    addi.w      a0,a0,0x4
    addi.w      a1,a1,0x4
    bne         a0,a2,stream_next

    b           FLUSH_DCACHE_AND_RETURN
```

## UTEST_MATRIX

```asm
UTEST_MATRIX:
    // set arguments
    li.w        a0, 0x1c400000
    li.w        a1, 0x1c410000
    li.w        a2, 0x1c420000
    li.w        a3, 96
    // a0 -> a
    // a1 -> b
    // a2 -> c
    // a3 -> n
    // t8 -> k
    // t1 -> i
    // t3 -> j, unrolled by 4
    // t7 -> r
    or          t8,zero,zero
loop1:
    beq         t8,a3,loop1end

    slli.w      t0,t8,2
    slli.w      t2,t8,9
    add.w       t0,a0,t0
    add.w       t2,a1,t2
    or          t1,zero,zero
loop2:
    beq         t1,a3,loop2end

    ld.w        t7,t0,0x0
    slli.w      a4,t1,9
    add.w       a4,a2,a4
    or          t4,t2,zero
    or          t3,zero,zero
loop3:
    beq         t3,a3,loop3end

    ld.w        t5,t4,0x0
    ld.w        t6,t4,0x4
    ld.w        s0,t4,0x8
    ld.w        s1,t4,0xc
    ld.w        s2,a4,0x0
    ld.w        s3,a4,0x4
    ld.w        s4,a4,0x8
    ld.w        s5,a4,0xc
    mul.w       t5,t7,t5
    mul.w       t6,t7,t6
    mul.w       s0,t7,s0
    mul.w       s1,t7,s1
    add.w       s2,s2,t5
    add.w       s3,s3,t6
    add.w       s4,s4,s0
    add.w       s5,s5,s1
    st.w        s2,a4,0x0
    st.w        s3,a4,0x4
    st.w        s4,a4,0x8
    st.w        s5,a4,0xc
    addi.w      t3,t3,4
    addi.w      a4,a4,16
    addi.w      t4,t4,16
    b           loop3

loop3end:
    addi.w      t1,t1,1
    addi.w      t0,t0,512
    b           loop2

loop2end:
    addi.w      t8,t8,1
    b           loop1

loop1end:
    b           FLUSH_DCACHE_AND_RETURN
```

## UTEST_CRYPTONIGHT

```asm
UTEST_CRYPTONIGHT:
    // a0 -> pad
    // a1 -> a
    // a2 -> b
    // a3 -> n
    li.w        a0, 0x1c400000
    li.w        a1, 0xdeadbeef
    li.w        a2, 0xfaceb00c
    li.w        a3, 0x100000
    or          t4,zero,a0
    or          t3,zero,zero
    li.w        t0,0x80000
fill_next:
    st.w        t3,t4,0
    addi.w      t3,t3,1
    addi.w      t4,t4,4
    bne         t3,t0,fill_next

    or          t1,zero,zero
    li.w        t2,0x7ffff
crn_hext:
    and         t0,a1,t2
    slli.w      t0,t0,2
    add.w       t0,a0,t0
    ld.w        t3,t0,0
    srli.w      t4,a1,1
    slli.w      t3,t3,1
    xor         t3,t3,t4
    and         t4,t3,t2
    xor         a2,t3,a2
    slli.w      t4,t4,2
    st.w        a2,t0,0
    add.w       t4,a0,t4
    ld.w        t0,t4,0
    or          a2,zero,t3
    mul.w       t3,t3,t0
    addi.w      t1,t1,1
    add.w       a1,t3,a1
    st.w        a1,t4,0
    xor         a1,t0,a1
    bne         a3,t1,crn_hext
crn_end:
    b           FLUSH_DCACHE_AND_RETURN
```

## UTEST_MIXED

```asm
UTEST_MIXED:
    li.w        a0,0x1c500000           // scratch source
    li.w        a1,0x1c510000           // scratch destination
    li.w        a2,0x4000               // 16K words = 64 KiB
    or          t0,zero,zero
    li.w        t1,0x9e37
mixed_fill:
    xor         t2,t0,t1
    slli.w      t3,t0,3
    xor         t2,t2,t3
    st.w        t2,a0,0x0
    addi.w      a0,a0,4
    addi.w      t0,t0,1
    bne         t0,a2,mixed_fill

    li.w        a0,0x1c500000
    li.w        a1,0x1c510000
    or          t0,zero,zero
    or          s0,zero,zero
    or          s1,zero,zero
    or          s2,zero,zero
    or          s3,zero,zero
mixed_stream:
    ld.w        t4,a0,0x0
    ld.w        t5,a0,0x4
    ld.w        t6,a0,0x8
    ld.w        t7,a0,0xc
    add.w       s0,s0,t4
    xor         s1,s1,t5
    add.w       s2,s2,t6
    xor         s3,s3,t7
    st.w        s0,a1,0x0
    st.w        s1,a1,0x4
    st.w        s2,a1,0x8
    st.w        s3,a1,0xc
    addi.w      a0,a0,16
    addi.w      a1,a1,16
    addi.w      t0,t0,4
    bne         t0,a2,mixed_stream

    li.w        a0,0x1c500000
    li.w        t0,0x2000               // indexed update iterations
    li.w        t8,0x3fff               // 64 KiB word-index mask
    xor         t1,s0,s1                // pseudo-random state
mixed_stride:
    and         t2,t1,t8
    slli.w      t2,t2,2
    add.w       t3,a0,t2
    ld.w        t4,t3,0x0
    xor         t1,t1,t4
    slli.w      t5,t1,5
    xor         t1,t1,t5
    srli.w      t5,t1,7
    xor         t1,t1,t5
    andi        t5,t1,0x1
    beq         t5,zero,mixed_even
    add.w       s0,s0,t4
    b           mixed_join
mixed_even:
    xor         s1,s1,t4
mixed_join:
    st.w        t1,t3,0x0
    addi.w      t0,t0,-1
    bne         t0,zero,mixed_stride

    li.w        a0,0x1c520000
    st.w        s0,a0,0x0
    st.w        s1,a0,0x4
    st.w        s2,a0,0x8
    st.w        s3,a0,0xc
    st.w        t1,a0,0x10
    b           FLUSH_DCACHE_AND_RETURN
```
