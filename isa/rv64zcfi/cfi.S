# See LICENSE for license details.

#*****************************************************************************
# csr.S
#-----------------------------------------------------------------------------
#
# Test cfi extension
#

#include "riscv_test.h"
#include "test_macros.h"

#if __riscv_xlen == 64
# define STORE    sd
# define LOAD     ld
# define REGBYTES 8
#else
# define STORE    sw
# define LOAD     lw
# define REGBYTES 4
#endif

#define CFI_TESTS

#define REG_NUM(reg) (0##reg - 0)

#define SS_PUSH_MASK 0b10000001110000000100000001110011
#define SS_POP_MASK  0b10000001110000000100000001110011 
#define SS_READ      0b10000001110100000100000001110011 
#define SS_CHECKRA   0b10001010000100101100000001110011
#define SS_AMOSWAP   0b10000010000000000100000001110011

#define LP_S_LL_MASK 0b10000010000000000100000001110011
#define LP_C_LL_MASK 0b10000011000000000100000001110011

#define LP_S_ML_MASK 0b10000110000000000100000001110011
#define LP_C_ML_MASK 0b10000110100000000100000001110011

#define LP_S_UL_MASK 0b10001011000000000100000001110011
#define LP_C_UL_MASK 0b10001011100000000100000001110011

#define LOWER_LABEL_MASK ((1<<9)-1)
#define LABEL_MASK       ((1<<8)-1)

#define RS1_SHIFT 15
#define RS2_SHIFT 20
#define RD_SHIFT 7

#define BCFI_SSMEM_LOAD_TEST     1
#define BCFI_SSMEM_STORE_TEST    2
#define BCFI_SSMEM_SS_OP_TEST    3
#define BCFI_RWMEM_SS_LOAD_TEST  5
#define BCFI_RWMEM_SS_STORE_TEST 6
#define BCFI_CHECKRA_PASS        7
#define BCFI_CHECKRA_FAIL        8
#define BCFI_SSP_READ            9
#define BCFI_SSP_AMOSWAP         10

#define FCFI_MISSING_LP         20
#define FCFI_LP_NONALIGNED      21
#define FCFI_LPLL_CHECK_PASS    22
#define FCFI_LPLL_CHECK_FAIL    23
#define FCFI_LPML_CHECK_PASS    24
#define FCFI_LPML_CHECK_FAIL    25
#define FCFI_LPUL_CHECK_PASS    26
#define FCFI_LPUL_CHECK_FAIL    27

/* Magic markers for negative and positive test */
#define NEGATIVE_TEST           0xCF11
#define POSITIVE_TEST           0xCF12

/* sspush only allows rs1 as x1 and x5. Below macro doesn't care about that */
.macro sspush regname
    .word SS_PUSH_MASK | (REG_NUM(\regname)) << RS1_SHIFT
.endm

/* sspop only allowed rd as x1 and x5. Below macro doesn't care about that */
.macro sspop regname
    .word SS_POP_MASK | (REG_NUM(\regname)) << RD_SHIFT
.endm

/* ssprr can read current ssp in any register */
.macro ssprr regname
    .word SS_READ | (REG_NUM(\regname)) << RD_SHIFT
.endm

/* sscheckra */
.macro sscheckra
    .word SS_CHECKRA
.endm

.macro ssamoswap dest, rs1, rs2
    .word SS_AMOSWAP | (REG_NUM(\dest)) << RD_SHIFT | (REG_NUM(\rs1)) << RS1_SHIFT | (REG_NUM(\rs2)) << RS2_SHIFT
.endm

/* lpsll */
.macro lpsll lowerlabel
    .word LP_S_LL_MASK | (((\lowerlabel) & LOWER_LABEL_MASK) << RS1_SHIFT)
.endm

/* lpcll */
.macro lpcll lowerlabel
    .word LP_C_LL_MASK | (((\lowerlabel) & LOWER_LABEL_MASK) << RS1_SHIFT)
.endm

/* lpsml */
.macro lpsml midlabel
    .word LP_S_ML_MASK | (((\midlabel) & LABEL_MASK) << RS1_SHIFT)
.endm

/* lpcml */
.macro lpcml midlabel
    .word LP_C_ML_MASK | (((\midlabel) & LABEL_MASK) << RS1_SHIFT)
.endm

/* lpsul */
.macro lpsul uplabel
    .word LP_S_UL_MASK | (((\uplabel) & LABEL_MASK) << RS1_SHIFT)
.endm

/* lpcul */
.macro lpcul uplabel
    .word LP_C_UL_MASK | (((\uplabel) & LABEL_MASK) << RS1_SHIFT)
.endm

#undef EXTRA_INIT
#define EXTRA_INIT                                                      \
    csrr t1, CSR_MENVCFG;                                               \
    li t0, MENVCFG_CFI;                                                 \
    or t0, t0, t1;                                                      \
    csrw CSR_MENVCFG, t0;                                               \
    csrr t1, CSR_MSTATUS;                                               \
    li t0, (MSTATUS_UFCFIEN |  MSTATUS_UBCFIEN);                        \
    or t0, t0, t1;                                                      \
    csrw CSR_MSTATUS, t0;                                               \
    la t0, shadow_stack_page_end - DRAM_BASE;                           \
    csrw CSR_SSP, t0;

#define KERNEL_BASE 0xffffffffffe00000
#undef FILTER_PAGE_FAULT
#define FILTER_PAGE_FAULT                                               \
    move t2, a0;                                                        \
    li a0, 0;                                                           \
    la t0, shadow_stack_page_start - KERNEL_BASE;                       \
    la t1, shadow_stack_page_end - KERNEL_BASE;                         \
    bltu t2, t0, 1f;                                                    \
    bgtu t2, t1, 1f;                                                    \
    li t0, (PTE_V | PTE_U | PTE_W);                                     \
    sd t0, (a1);                                                        \
    li t0, 0;                                                           \
    sw t0, (a2);                                                        \
    li a0, 1;                                                           \
1:                                                                      \
    ret;

/*
* Filtering trap is required because
*   - to test cases for cfi instruction(s) which must raise illegal instr exception
*   - if a cfi test fails, supervisor must terminate
*
* Trap filter will get called for all other traps too. We need to narrow down filter
* as much as possible. Only need to do filtering for two causes
*   - CAUSE_ILLEGAL_INSTRUCTION (tests of sscheckra, lpcll, lpcml, lpcul)
*   - CAUSE_STORE_ACCESS (regular store to SS memory or sspush on regular memory)
*   - CAUSE_LOAD_ACCESS (sspop on regular memory)
*   - CAUSE_USER_ECALL
*       - Further check if x30 contains 0xbaddea1 that means one of the test went bad
*         In this case, just stop everything
* If trap is due to test case then copy cause code into x28, do epc += 4 and resume
*
* Trap handler gets pointer to trap frame (in a0)
*/

#undef FILTER_TRAP
#define FILTER_TRAP                                                     \
    move a1, a0;                                                        \
    li a0, 0;                                                           \
    LOAD  t0,35*REGBYTES(a1);                                           \
    li t1, CAUSE_ILLEGAL_INSTRUCTION;                                   \
    beq t0, t1, check_neg_test;                                         \
    li t1, CAUSE_LOAD_ACCESS;                                           \
    beq t0, t1, check_neg_test;                                         \
    li t1, CAUSE_STORE_ACCESS;                                          \
    beq t0, t1, check_neg_test;                                         \
    li t1, CAUSE_USER_ECALL;                                            \
    bne t0, t1, no_filter;                                              \
    LOAD t1,30*REGBYTES(a1);                                            \
    li t2, 0xbaddea1;                                                   \
    bne t1, t2, no_filter;                                              \
    j term_test;                                                        \
check_neg_test:                                                         \
    /* any fault/exception is a negative test */                        \
    LOAD t1,29*REGBYTES(a1);                                            \
    li t2, NEGATIVE_TEST;                                               \
    bne t2, t1, no_filter;                                              \
    STORE t0, 28*REGBYTES(a1);                                          \
    /* get epc and increment by 4 */                                    \
    LOAD t1,33*REGBYTES(a1);                                            \
    addi t1, t1, 4;                                                     \
    STORE t1,33*REGBYTES(a1);                                           \
term_test:                                                              \
    li a0, 1;                                                           \
no_filter:                                                              \
    ret;

RVTEST_RV64U
RVTEST_CODE_BEGIN

/*
* CFI tests
* x29 contains whether a negative test or positive test
* 1 is positive test. 0 is negative test
* If test resulted in fault, x28 will contain cause (via trap filter)
*/

/* regular load on ss memory. must succeed */
    TEST_CASE(BCFI_SSMEM_LOAD_TEST, x6, 0, \
    li x29, POSITIVE_TEST; \
    la x6, shadow_stack_page_end - 8;  \
    ld x6, 0(x6); \
    )

/* regular store on ss memory. must do store_access_fault */
    TEST_CASE(BCFI_SSMEM_STORE_TEST, x28, CAUSE_STORE_ACCESS, \
    li x28, 0; \
    li x29, NEGATIVE_TEST; \
    la x6, shadow_stack_page_end - 8;  \
    sd x6, 0(x6); \
    )

/* ss load/store on ss memory. must not fault/trap */
    TEST_CASE(BCFI_SSMEM_SS_OP_TEST, x5, 0xdeadbeef, \
    li x29, POSITIVE_TEST; \
    li x1, 0xdeadbeef; \
    sspush x1; \
    sspop x5; \
    )

/* sscheckra mustn't fault  */
    TEST_CASE(BCFI_CHECKRA_PASS, x28, 0, \
    li x28, 0; \
    li x29, POSITIVE_TEST; \
    li x1, 0xdeadbeef; \
    li x5, 0xdeadbeef; \
    sscheckra; \
    )

/* sscheckra must fault  */
    TEST_CASE(BCFI_CHECKRA_FAIL, x28, CAUSE_ILLEGAL_INSTRUCTION, \
    li x28, 0; \
    li x29, NEGATIVE_TEST; \
    li x1, 0xdeadbeef; \
    li x5, 0xbeefdead; \
    sscheckra; \
    )

/* ssprr test to test SSP read is working  */
    TEST_CASE(BCFI_SSP_READ, x6, 0, \
    li x6, 1; \
    li x29, POSITIVE_TEST; \
    ssprr x5; \
    beqz x5, 1f; \
    li x6, 0; \
1:            \
    )

/* TODO: ssamoswap test to test amoswap on SS is working  */
    TEST_CASE(BCFI_SSP_AMOSWAP, x6, 1, \
    li x6, 0; \
    li x29, POSITIVE_TEST; \
    ssprr x5; \
    move x7, x5 ;\
    beqz x5, 1f; \
    sspush x5; \
    ssprr x5; \
    ssamoswap x5, x5, x0; \
    bne x5, x7, 1f; \
    li x6, 1; \
1:            \
    )

/* regular memory but ss load. must raise load_access_fault */
    TEST_CASE(BCFI_RWMEM_SS_LOAD_TEST, x28, CAUSE_LOAD_ACCESS, \
    li x29, NEGATIVE_TEST; \
    ssprr x1; \
    la x2, data_stack_start + 8; \
    ld x7, 0(x2); \
    csrw CSR_SSP, x2; \
    sspop x1; \
    csrw CSR_SSP, x1; \
    )

/* regular memory but ss store. must raise store_access_fault */
    TEST_CASE(BCFI_RWMEM_SS_STORE_TEST, x28, CAUSE_STORE_ACCESS, \
    li x29, NEGATIVE_TEST; \
    ssprr x1; \
    la x2, data_stack_start + 8; \
    ld x7, 0(x2); \
    csrw CSR_SSP, x2; \
    sspush x1; \
    csrw CSR_SSP, x1; \
    )

#define LOWER_LABEL 123
#define MID_LABEL 124
#define UP_LEVEL 125

/* Missing a landing pad, must fault  */
    TEST_CASE(FCFI_MISSING_LP, x28, CAUSE_ILLEGAL_INSTRUCTION, \
    la x6, indirect_landing_pad_1; \
    li x28, 0; \
    li x29, NEGATIVE_TEST; \
    lpsll LOWER_LABEL; \
    jalr x7,x6; \
indirect_landing_pad_1: \
/* nop should fault but filter trap handler should advance epc and `lpcll` should succeed */
    nop; \
    lpcll LOWER_LABEL; \
    )

/* Check lower label, positive test  */
    TEST_CASE(FCFI_LPLL_CHECK_PASS, x28, 0, \
    la x6, indirect_landing_pad_2; \
    li x28, 0; \
    li x29, POSITIVE_TEST; \
    lpsll LOWER_LABEL; \
    jalr x7,x6; \
indirect_landing_pad_2: \
    lpcll LOWER_LABEL; \
    )

/* Check lower label, negative test  */
    TEST_CASE(FCFI_LPLL_CHECK_FAIL, x28, CAUSE_ILLEGAL_INSTRUCTION, \
    la x6, indirect_landing_pad_3; \
    li x28, 0; \
    li x29, NEGATIVE_TEST; \
    lpsll LOWER_LABEL; \
    jalr x7,x6; \
indirect_landing_pad_3: \
    lpcll 0; \
    )

/* Check mid label, positive test  */
    TEST_CASE(FCFI_LPML_CHECK_PASS, x28, 0, \
    li x28, 0; \
    li x29, POSITIVE_TEST; \
    lpsml MID_LABEL; \
    lpcml MID_LABEL; \
    )

/* Check mid label, negative test  */
    TEST_CASE(FCFI_LPML_CHECK_FAIL, x28, CAUSE_ILLEGAL_INSTRUCTION, \
    li x28, 0; \
    li x29, NEGATIVE_TEST; \
    lpsml MID_LABEL; \
    lpcml 0; \
    )

/* Check up label, positive test  */
    TEST_CASE(FCFI_LPUL_CHECK_PASS, x28, 0, \
    li x28, 0; \
    li x29, POSITIVE_TEST; \
    lpsul 125; \
    lpcul 125; \
    )

/* Check up label, negative test  */
    TEST_CASE(FCFI_LPUL_CHECK_FAIL, x28, CAUSE_ILLEGAL_INSTRUCTION, \
    li x28, 0; \
    li x29, NEGATIVE_TEST; \
    lpsul 125; \
    lpcul 0; \
    )
/* all tests passed */
pass:
    j pass;

/* TESTNUM (gp) holds test number. */
fail:
/* special marker to end the run */
    li x30, 0xbaddea1;
    scall;

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN

.balign PGSIZE
.global data_stack_start
data_stack_start:
    .fill 512, 8, 0
.global data_stack_end
data_stack_end:

.balign PGSIZE
.global shadow_stack_page_start
shadow_stack_page_start:
    .fill 512, 8, -1
.global shadow_stack_page_end
shadow_stack_page_end:
RVTEST_DATA_END
