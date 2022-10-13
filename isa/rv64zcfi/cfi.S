# See LICENSE for license details.

#*****************************************************************************
# csr.S
#-----------------------------------------------------------------------------
#
# Test cfi extension
#

#include "riscv_test.h"
#include "test_macros.h"

#define CFI_TESTS

#define REG_NUM(reg) (0##reg - 0)

#define SS_PUSH_MASK 0b10000001110000000100000001110011
#define SS_POP_MASK  0b10000001110000000100000001110011 
#define SS_READ      0b10000001110100000100000001110011 
#define SS_CHECKRA   0b10001010000100101100000001110011

#define RS1_SHIFT 15
#define RD_SHIFT 7

/* sspush only allows rd as x1 and x5. Below macro doesn't care about that */
.macro sspush regname
    .word SS_PUSH_MASK | (REG_NUM(\regname)) << RS1_SHIFT
.endm

/* sspop only allowed rs1 as x1 and x5. Below macro doesn't care about that */
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


#undef EXTRA_INIT
#define EXTRA_INIT                                                      \
  la t0, CFISTATUS_UBCFIEN;                                             \
  csrw CSR_SCFISTATUS, t0;                                              \
  la t0, shadow_stack_page_end - DRAM_BASE;                             \
  csrw CSR_USSP, t0;

RVTEST_RV64U
RVTEST_CODE_BEGIN

li x1, 0xdeadbeef
sspush x1
sspop x5
sscheckra
1:
j 1b

RVTEST_CODE_END

.data
RVTEST_DATA_BEGIN

.balign PGSIZE
.global shadow_stack_page_start
shadow_stack_page_start:
.fill 512, 8, 0
.global shadow_stack_page_end
shadow_stack_page_end:
RVTEST_DATA_END
