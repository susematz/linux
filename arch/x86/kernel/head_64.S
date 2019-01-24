/*
 *  linux/arch/x86/kernel/head_64.S -- start in 32bit and switch to 64bit
 *
 *  Copyright (C) 2000 Andrea Arcangeli <andrea@suse.de> SuSE
 *  Copyright (C) 2000 Pavel Machek <pavel@suse.cz>
 *  Copyright (C) 2000 Karsten Keil <kkeil@suse.de>
 *  Copyright (C) 2001,2002 Andi Kleen <ak@suse.de>
 *  Copyright (C) 2005 Eric Biederman <ebiederm@xmission.com>
 */


#include <linux/linkage.h>
#include <linux/threads.h>
#include <linux/init.h>
#include <asm/segment.h>
#include <asm/pgtable.h>
#include <asm/page.h>
#include <asm/msr.h>
#include <asm/cache.h>
#include <asm/processor-flags.h>
#include <asm/percpu.h>
#include <asm/nops.h>

#ifdef CONFIG_PARAVIRT
#include <asm/asm-offsets.h>
#include <asm/paravirt.h>
#define GET_CR2_INTO(reg) GET_CR2_INTO_RAX ; movq %rax, reg
#else
#define GET_CR2_INTO(reg) movq %cr2, reg
#define INTERRUPT_RETURN iretq
#endif

/* we are not able to switch in one step to the final KERNEL ADDRESS SPACE
 * because we need identity-mapped pages.
 *
 */

#define pud_index(x)	(((x) >> PUD_SHIFT) & (PTRS_PER_PUD-1))

L4_PAGE_OFFSET = pgd_index(__PAGE_OFFSET)
L4_START_KERNEL = pgd_index(__START_KERNEL_map)
L3_START_KERNEL = pud_index(__START_KERNEL_map)

.section .multiboot, "aw", @progbits
#define MB_MAGIC 0x1badb002
#define MB_FLAGS 0x10003
#define MB_CHECKSUM -(MB_MAGIC + MB_FLAGS)

.align  4
.int    MB_MAGIC
.int    MB_FLAGS
.int    MB_CHECKSUM
.int    4096 - 0x200000 + 0x1000000  /* multiboot_uint32_t header_addr; */
.int    0x1000000  /* multiboot_uint32_t load_addr; */
.int    phys_bss_start  /* multiboot_uint32_t load_end_addr; */
.int    phys_end  /* multiboot_uint32_t bss_end_addr; */
.int    phys_mb_startup_32  /* multiboot_uint32_t entry_addr; */

	.text
	__HEAD
	.code64
	.globl startup_64
startup_64:
	/*
	 * At this point the CPU runs in 64bit mode CS.L = 1 CS.D = 0,
	 * and someone has loaded an identity mapped page table
	 * for us.  These identity mapped page tables map all of the
	 * kernel pages and possibly all of memory.
	 *
	 * %rsi holds a physical pointer to real_mode_data.
	 *
	 * We come here either directly from a 64bit bootloader, or from
	 * arch/x86/boot/compressed/head_64.S.
	 *
	 * We only come here initially at boot nothing else comes here.
	 *
	 * Since we may be loaded at an address different from what we were
	 * compiled to run at we first fixup the physical addresses in our page
	 * tables and then reload them.
	 */

	/* Sanitize CPU configuration */
	call verify_cpu

	/*
	 * Compute the delta between the address I am compiled to run at and the
	 * address I am actually running at.
	 */
	leaq	_text(%rip), %rbp
	subq	$_text - __START_KERNEL_map, %rbp

	/* Is the address not 2M aligned? */
	testl	$~PMD_PAGE_MASK, %ebp
	jnz	bad_address

	/*
	 * Is the address too large?
	 */
	leaq	_text(%rip), %rax
	shrq	$MAX_PHYSMEM_BITS, %rax
	jnz	bad_address

	/*
	 * Fixup the physical addresses in the page table
	 */
	addq	%rbp, early_level4_pgt + (L4_START_KERNEL*8)(%rip)

	addq	%rbp, level3_kernel_pgt + (510*8)(%rip)
	addq	%rbp, level3_kernel_pgt + (511*8)(%rip)

	addq	%rbp, level2_fixmap_pgt + (506*8)(%rip)

	/*
	 * Set up the identity mapping for the switchover.  These
	 * entries should *NOT* have the global bit set!  This also
	 * creates a bunch of nonsense entries but that is fine --
	 * it avoids problems around wraparound.
	 */
	leaq	_text(%rip), %rdi
	leaq	early_level4_pgt(%rip), %rbx

	movq	%rdi, %rax
	shrq	$PGDIR_SHIFT, %rax

	leaq	(4096 + _KERNPG_TABLE)(%rbx), %rdx
	movq	%rdx, 0(%rbx,%rax,8)
	movq	%rdx, 8(%rbx,%rax,8)

	addq	$4096, %rdx
	movq	%rdi, %rax
	shrq	$PUD_SHIFT, %rax
	andl	$(PTRS_PER_PUD-1), %eax
	movq	%rdx, 4096(%rbx,%rax,8)
	incl	%eax
	andl	$(PTRS_PER_PUD-1), %eax
	movq	%rdx, 4096(%rbx,%rax,8)

	addq	$8192, %rbx
	movq	%rdi, %rax
	shrq	$PMD_SHIFT, %rdi
	addq	$(__PAGE_KERNEL_LARGE_EXEC & ~_PAGE_GLOBAL), %rax
	leaq	(_end - 1)(%rip), %rcx
	shrq	$PMD_SHIFT, %rcx
	subq	%rdi, %rcx
	incl	%ecx

1:
	andq	$(PTRS_PER_PMD - 1), %rdi
	movq	%rax, (%rbx,%rdi,8)
	incq	%rdi
	addq	$PMD_SIZE, %rax
	decl	%ecx
	jnz	1b

	/*
	 * Fixup the kernel text+data virtual addresses. Note that
	 * we might write invalid pmds, when the kernel is relocated
	 * cleanup_highmap() fixes this up along with the mappings
	 * beyond _end.
	 */
	leaq	level2_kernel_pgt(%rip), %rdi
	leaq	4096(%rdi), %r8
	/* See if it is a valid page table entry */
1:	testb	$1, 0(%rdi)
	jz	2f
	addq	%rbp, 0(%rdi)
	/* Go to the next page */
2:	addq	$8, %rdi
	cmp	%r8, %rdi
	jne	1b

	/* Fixup phys_base */
	addq	%rbp, phys_base(%rip)

	movq	$(early_level4_pgt - __START_KERNEL_map), %rax
	jmp 1f
ENTRY(secondary_startup_64)
	/*
	 * At this point the CPU runs in 64bit mode CS.L = 1 CS.D = 0,
	 * and someone has loaded a mapped page table.
	 *
	 * %rsi holds a physical pointer to real_mode_data.
	 *
	 * We come here either from startup_64 (using physical addresses)
	 * or from trampoline.S (using virtual addresses).
	 *
	 * Using virtual addresses from trampoline.S removes the need
	 * to have any identity mapped pages in the kernel page table
	 * after the boot processor executes this code.
	 */

	/* Sanitize CPU configuration */
	call verify_cpu

	movq	$(init_level4_pgt - __START_KERNEL_map), %rax
1:

	/* Enable PAE mode and PGE */
	movl	$(X86_CR4_PAE | X86_CR4_PGE), %ecx
	movq	%rcx, %cr4

	/* Setup early boot stage 4 level pagetables. */
	addq	phys_base(%rip), %rax
	movq	%rax, %cr3

	/* Ensure I am executing from virtual addresses */
	movq	$1f, %rax
	jmp	*%rax
1:

	/* Check if nx is implemented */
	movl	$0x80000001, %eax
	cpuid
	movl	%edx,%edi

	/* Setup EFER (Extended Feature Enable Register) */
	movl	$MSR_EFER, %ecx
	rdmsr
	btsl	$_EFER_SCE, %eax	/* Enable System Call */
	btl	$20,%edi		/* No Execute supported? */
	jnc     1f
	btsl	$_EFER_NX, %eax
	btsq	$_PAGE_BIT_NX,early_pmd_flags(%rip)
1:	wrmsr				/* Make changes effective */

	/* Setup cr0 */
#define CR0_STATE	(X86_CR0_PE | X86_CR0_MP | X86_CR0_ET | \
			 X86_CR0_NE | X86_CR0_WP | X86_CR0_AM | \
			 X86_CR0_PG)
	movl	$CR0_STATE, %eax
	/* Make changes effective */
	movq	%rax, %cr0

	/* Setup a boot time stack */
	movq stack_start(%rip), %rsp

	/* zero EFLAGS after setting rsp */
	pushq $0
	popfq

	/*
	 * We must switch to a new descriptor in kernel space for the GDT
	 * because soon the kernel won't have access anymore to the userspace
	 * addresses where we're currently running on. We have to do that here
	 * because in 32bit we couldn't load a 64bit linear address.
	 */
	lgdt	early_gdt_descr(%rip)

	/* set up data segments */
	xorl %eax,%eax
	movl %eax,%ds
	movl %eax,%ss
	movl %eax,%es

	/*
	 * We don't really need to load %fs or %gs, but load them anyway
	 * to kill any stale realmode selectors.  This allows execution
	 * under VT hardware.
	 */
	movl %eax,%fs
	movl %eax,%gs

	/* Set up %gs.
	 *
	 * The base of %gs always points to the bottom of the irqstack
	 * union.  If the stack protector canary is enabled, it is
	 * located at %gs:40.  Note that, on SMP, the boot cpu uses
	 * init data section till per cpu areas are set up.
	 */
	movl	$MSR_GS_BASE,%ecx
	movl	initial_gs(%rip),%eax
	movl	initial_gs+4(%rip),%edx
	wrmsr	

	/* rsi is pointer to real mode structure with interesting info.
	   pass it to C */
	movq	%rsi, %rdi
	
	/* Finally jump to run C code and to be on real kernel address
	 * Since we are running on identity-mapped space we have to jump
	 * to the full 64bit address, this is only possible as indirect
	 * jump.  In addition we need to ensure %cs is set so we make this
	 * a far return.
	 *
	 * Note: do not change to far jump indirect with 64bit offset.
	 *
	 * AMD does not support far jump indirect with 64bit offset.
	 * AMD64 Architecture Programmer's Manual, Volume 3: states only
	 *	JMP FAR mem16:16 FF /5 Far jump indirect,
	 *		with the target specified by a far pointer in memory.
	 *	JMP FAR mem16:32 FF /5 Far jump indirect,
	 *		with the target specified by a far pointer in memory.
	 *
	 * Intel64 does support 64bit offset.
	 * Software Developer Manual Vol 2: states:
	 *	FF /5 JMP m16:16 Jump far, absolute indirect,
	 *		address given in m16:16
	 *	FF /5 JMP m16:32 Jump far, absolute indirect,
	 *		address given in m16:32.
	 *	REX.W + FF /5 JMP m16:64 Jump far, absolute indirect,
	 *		address given in m16:64.
	 */
	movq	initial_code(%rip),%rax
	pushq	$0		# fake return address to stop unwinder
	pushq	$__KERNEL_CS	# set correct cs
	pushq	%rax		# target address in negative space
	lretq

#include "verify_cpu.S"

#ifdef CONFIG_HOTPLUG_CPU
/*
 * Boot CPU0 entry point. It's called from play_dead(). Everything has been set
 * up already except stack. We just set up stack here. Then call
 * start_secondary().
 */
ENTRY(start_cpu0)
	movq stack_start(%rip),%rsp
	movq	initial_code(%rip),%rax
	pushq	$0		# fake return address to stop unwinder
	pushq	$__KERNEL_CS	# set correct cs
	pushq	%rax		# target address in negative space
	lretq
ENDPROC(start_cpu0)
#endif

	/* SMP bootup changes these two */
	__REFDATA
	.balign	8
	GLOBAL(initial_code)
	.quad	x86_64_start_kernel
	GLOBAL(initial_gs)
	.quad	INIT_PER_CPU_VAR(irq_stack_union)

	GLOBAL(stack_start)
	.quad  init_thread_union+THREAD_SIZE-8
	.word  0
	__FINITDATA

bad_address:
	jmp bad_address

	__INIT
ENTRY(early_idt_handler_array)
	# 104(%rsp) %rflags
	#  96(%rsp) %cs
	#  88(%rsp) %rip
	#  80(%rsp) error code
	i = 0
	.rept NUM_EXCEPTION_VECTORS
	.ifeq (EXCEPTION_ERRCODE_MASK >> i) & 1
	pushq $0		# Dummy error code, to make stack frame uniform
	.endif
	pushq $i		# 72(%rsp) Vector number
	jmp early_idt_handler_common
	i = i + 1
	.fill early_idt_handler_array + i*EARLY_IDT_HANDLER_SIZE - ., 1, 0xcc
	.endr
ENDPROC(early_idt_handler_array)

early_idt_handler_common:
	/*
	 * The stack is the hardware frame, an error code or zero, and the
	 * vector number.
	 */
	cld

	cmpl $2,(%rsp)		# X86_TRAP_NMI
	je .Lis_nmi		# Ignore NMI

	cmpl $2,early_recursion_flag(%rip)
	jz  1f
	incl early_recursion_flag(%rip)

	pushq %rax		# 64(%rsp)
	pushq %rcx		# 56(%rsp)
	pushq %rdx		# 48(%rsp)
	pushq %rsi		# 40(%rsp)
	pushq %rdi		# 32(%rsp)
	pushq %r8		# 24(%rsp)
	pushq %r9		# 16(%rsp)
	pushq %r10		#  8(%rsp)
	pushq %r11		#  0(%rsp)

	cmpl $__KERNEL_CS,96(%rsp)
	jne 11f

	cmpl $14,72(%rsp)	# Page fault?
	jnz 10f
	GET_CR2_INTO(%rdi)	# can clobber any volatile register if pv
	call early_make_pgtable
	andl %eax,%eax
	jz 20f			# All good

10:
	leaq 88(%rsp),%rdi	# Pointer to %rip
	call early_fixup_exception
	andl %eax,%eax
	jnz 20f			# Found an exception entry

11:
#ifdef CONFIG_EARLY_PRINTK
	GET_CR2_INTO(%r9)	# can clobber any volatile register if pv
	movl 80(%rsp),%r8d	# error code
	movl 72(%rsp),%esi	# vector number
	movl 96(%rsp),%edx	# %cs
	movq 88(%rsp),%rcx	# %rip
	xorl %eax,%eax
	leaq early_idt_msg(%rip),%rdi
	call early_printk
	cmpl $2,early_recursion_flag(%rip)
	jz  1f
	call dump_stack
#ifdef CONFIG_KALLSYMS	
	leaq early_idt_ripmsg(%rip),%rdi
	movq 40(%rsp),%rsi	# %rip again
	call __print_symbol
#endif
#endif /* EARLY_PRINTK */
1:	hlt
	jmp 1b

20:	# Exception table entry found or page table generated
	popq %r11
	popq %r10
	popq %r9
	popq %r8
	popq %rdi
	popq %rsi
	popq %rdx
	popq %rcx
	popq %rax
	decl early_recursion_flag(%rip)
.Lis_nmi:
	addq $16,%rsp		# drop vector number and error code
	INTERRUPT_RETURN
ENDPROC(early_idt_handler_common)

	__INITDATA

	.balign 4
early_recursion_flag:
	.long 0

#ifdef CONFIG_EARLY_PRINTK
early_idt_msg:
	.asciz "PANIC: early exception %02lx rip %lx:%lx error %lx cr2 %lx\n"
early_idt_ripmsg:
	.asciz "RIP %s\n"
#endif /* CONFIG_EARLY_PRINTK */

#define NEXT_PAGE(name) \
	.balign	PAGE_SIZE; \
GLOBAL(name)

/* Automate the creation of 1 to 1 mapping pmd entries */
#define PMDS(START, PERM, COUNT)			\
	i = 0 ;						\
	.rept (COUNT) ;					\
	.quad	(START) + (i << PMD_SHIFT) + (PERM) ;	\
	i = i + 1 ;					\
	.endr

	__INITDATA
NEXT_PAGE(early_level4_pgt)
	.fill	511,8,0
	.quad	level3_kernel_pgt - __START_KERNEL_map + _PAGE_TABLE

NEXT_PAGE(early_dynamic_pgts)
	.fill	512*EARLY_DYNAMIC_PAGE_TABLES,8,0

	.data

#ifndef CONFIG_XEN
NEXT_PAGE(init_level4_pgt)
	.fill	512,8,0
#else
NEXT_PAGE(init_level4_pgt)
	.quad   level3_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE
	.org    init_level4_pgt + L4_PAGE_OFFSET*8, 0
	.quad   level3_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE
	.org    init_level4_pgt + L4_START_KERNEL*8, 0
	/* (2^48-(2*1024*1024*1024))/(2^39) = 511 */
	.quad   level3_kernel_pgt - __START_KERNEL_map + _PAGE_TABLE

NEXT_PAGE(level3_ident_pgt)
	.quad	level2_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE
	.fill	511, 8, 0
NEXT_PAGE(level2_ident_pgt)
	/* Since I easily can, map the first 1G.
	 * Don't set NX because code runs from these pages.
	 */
	PMDS(0, __PAGE_KERNEL_IDENT_LARGE_EXEC, PTRS_PER_PMD)
#endif

NEXT_PAGE(level3_kernel_pgt)
	.fill	L3_START_KERNEL,8,0
	/* (2^48-(2*1024*1024*1024)-((2^39)*511))/(2^30) = 510 */
	.quad	level2_kernel_pgt - __START_KERNEL_map + _KERNPG_TABLE
	.quad	level2_fixmap_pgt - __START_KERNEL_map + _PAGE_TABLE

NEXT_PAGE(level2_kernel_pgt)
	/*
	 * 512 MB kernel mapping. We spend a full page on this pagetable
	 * anyway.
	 *
	 * The kernel code+data+bss must not be bigger than that.
	 *
	 * (NOTE: at +512MB starts the module area, see MODULES_VADDR.
	 *  If you want to increase this then increase MODULES_VADDR
	 *  too.)
	 */
	PMDS(0, __PAGE_KERNEL_LARGE_EXEC,
		KERNEL_IMAGE_SIZE/PMD_SIZE)

NEXT_PAGE(level2_fixmap_pgt)
	.fill	506,8,0
	.quad	level1_fixmap_pgt - __START_KERNEL_map + _PAGE_TABLE
	/* 8MB reserved for vsyscalls + a 2MB hole = 4 + 1 entries */
	.fill	5,8,0

NEXT_PAGE(level1_fixmap_pgt)
	.fill	512,8,0

#undef PMDS

	.data
	.align 16
	.globl early_gdt_descr
early_gdt_descr:
	.word	GDT_ENTRIES*8-1
early_gdt_descr_base:
	.quad	INIT_PER_CPU_VAR(gdt_page)

ENTRY(phys_base)
	/* This must match the first entry in level2_kernel_pgt */
	.quad   0x0000000000000000

#include "../../x86/xen/xen-head.S"
	
	__PAGE_ALIGNED_BSS
NEXT_PAGE(empty_zero_page)
	.skip PAGE_SIZE

/* ===================================================== */
/* multiboot 32bit startup code */
	.code32
	.text

#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/boot.h>
#include <asm/msr.h>
#include <asm/processor-flags.h>
#include <asm/asm-offsets.h>
#include <asm/bootparam.h>

	.code32
ENTRY(mb_startup_32)
	/*
	 * 32bit entry is 0 and it is ABI so immutable!
	 * If we come here directly from a bootloader,
	 * kernel(text+data+bss+brk) ramdisk, zero_page, command line
	 * all need to be under the 4G limit.
	 */
	cld

	/* ebx contains physical address of multiboot info */
	mov	%ebx, %esi
/*
 * Calculate the delta between where we were compiled to run
 * at and where we were actually loaded at.  This can only be done
 * with a short local call on x86.  Nothing  else will tell us what
 * address we are running at.  The reserved chunk of the real-mode
 * data at 0x1e4 (defined as a scratch field) are used as the stack
 * for this calculation. Only 4 bytes are needed.
 */
	mov	(%esi), %ebx
	leal	4(%esi), %esp
	call	1f
1:	popl	%ebp
	subl	$1b - __START_KERNEL_map, %ebp
	mov	%ebx,(%esi)

/* setup a stack and make sure cpu supports long mode. */
	movl	$boot_stack_end - __START_KERNEL_map, %eax
	addl	%ebp, %eax
	movl	%eax, %esp

	/* Should verify cpu here for longmode */

/*
 * Prepare for entering 64 bit mode
 */

	/* Load new GDT with the 64bit segments using 32bit descriptor */
	leal	gdt - __START_KERNEL_map(%ebp), %eax
	movl	%eax, gdt+2 - __START_KERNEL_map(%ebp)
	lgdt	gdt - __START_KERNEL_map(%ebp)

	/* Enable PAE mode */
	movl	%cr4, %eax
	orl	$X86_CR4_PAE, %eax
	movl	%eax, %cr4

 /*
  * Build early 4G boot pagetable
  */
	/* Initialize Page tables to 0 */
	/*leal	pgtable(%ebx), %edi*/
	leal	pgtable - __START_KERNEL_map(%ebp), %edi
	xorl	%eax, %eax
	movl	$((4096*6)/4), %ecx
	rep	stosl

	/* Build Level 4 */
	leal	pgtable + 0 - __START_KERNEL_map(%ebp), %edi
	leal	0x1007 (%edi), %eax
	movl	%eax, 0(%edi)

	/* Build Level 3 */
	leal	pgtable + 0x1000 - __START_KERNEL_map(%ebp), %edi
	leal	0x1007(%edi), %eax
	movl	$4, %ecx
1:	movl	%eax, 0x00(%edi)
	addl	$0x00001000, %eax
	addl	$8, %edi
	decl	%ecx
	jnz	1b

	/* Build Level 2 */
	leal	pgtable + 0x2000 - __START_KERNEL_map(%ebp), %edi
	movl	$0x00000183, %eax
	movl	$2048, %ecx
1:	movl	%eax, 0(%edi)
	addl	$0x00200000, %eax
	addl	$8, %edi
	decl	%ecx
	jnz	1b

	/* Enable the boot page tables */
	leal	pgtable - __START_KERNEL_map(%ebp), %eax
	movl	%eax, %cr3

	/* Enable Long mode in EFER (Extended Feature Enable Register) */
	movl	$MSR_EFER, %ecx
	rdmsr
	btsl	$_EFER_LME, %eax
	wrmsr

	/* After gdt is loaded */
	xorl	%eax, %eax
	lldt	%ax
	movl    $__BOOT_TSS, %eax
	ltr	%ax

	/*
	 * Setup for the jump to 64bit mode
	 *
	 * When the jump is performend we will be in long mode but
	 * in 32bit compatibility mode with EFER.LME = 1, CS.L = 0, CS.D = 1
	 * (and in turn EFER.LMA = 1).	To jump into 64bit mode we use
	 * the new gdt/idt that has __KERNEL_CS with CS.L = 1.
	 * We place all of the values on our mini stack so lret can
	 * used to perform that far jump.
	 */
	pushl	$__KERNEL_CS
	leal	mb_startup_64 - __START_KERNEL_map(%ebp), %eax
	pushl	%eax

	/* Enter paged protected Mode, activating Long Mode */
	movl	$(X86_CR0_PG | X86_CR0_PE), %eax /* Enable Paging and Protected mode */
	movl	%eax, %cr0

	/* Jump from 32bit compatibility mode into 64bit mode. */
	lret
ENDPROC(mb_startup_32)

	.code64
ENTRY(mb_startup_64)
	/*
	 * 64bit entry is 0x200 and it is ABI so immutable!
	 * We come here either from startup_32 or directly from a
	 * 64bit bootloader.
	 * If we come here from a bootloader, kernel(text+data+bss+brk),
	 * ramdisk, zero_page, command line could be above 4G.
	 * We depend on an identity mapped page table being provided
	 * that maps our entire kernel(text+data+bss+brk), zero page
	 * and command line.
	 */
	/* Setup data segments. */
	xorl	%eax, %eax
	movl	%eax, %ds
	movl	%eax, %es
	movl	%eax, %ss
	movl	%eax, %fs
	movl	%eax, %gs

	or	$1, %rsi
	jmp startup_64

	.code32
no_longmode:
	/* This isn't an x86-64 CPU so hang */
1:
	hlt
	jmp     1b

	.data
gdt:
	.word	gdt_end - gdt
	.long	gdt - __START_KERNEL_map
	.word	0
	.quad	0x0000000000000000	/* NULL descriptor */
	.quad	0x00af9a000000ffff	/* __KERNEL_CS */
	.quad	0x00cf92000000ffff	/* __KERNEL_DS */
	.quad	0x0080890000000000	/* TS descriptor */
	.quad   0x0000000000000000	/* TS continued */
gdt_end:

/*
 * Stack and heap for uncompression
 */
	.bss
	.balign 4
boot_heap:
	.fill BOOT_HEAP_SIZE, 1, 0
boot_stack:
	.fill BOOT_STACK_SIZE, 1, 0
boot_stack_end:

/*
 * Space for page tables (not in .bss so not zeroed)
 */
	.data
	.balign 4096
pgtable:
	.fill 6*4096, 1, 0
