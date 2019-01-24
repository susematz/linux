/*
 *  prepare to run common code
 *
 *  Copyright (C) 2000 Andrea Arcangeli <andrea@suse.de> SuSE
 */

#include <linux/init.h>
#include <linux/linkage.h>
#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/percpu.h>
#include <linux/start_kernel.h>
#include <linux/io.h>
#include <linux/memblock.h>

#include <asm/processor.h>
#include <asm/proto.h>
#include <asm/smp.h>
#include <asm/setup.h>
#include <asm/desc.h>
#include <asm/pgtable.h>
#include <asm/tlbflush.h>
#include <asm/sections.h>
#include <asm/kdebug.h>
#include <asm/e820.h>
#include <asm/bios_ebda.h>
#include <asm/bootparam_utils.h>
#include <asm/microcode.h>
#include <asm/kasan.h>

/*
 * Manage page tables very early on.
 */
extern pgd_t early_level4_pgt[PTRS_PER_PGD];
extern pmd_t early_dynamic_pgts[EARLY_DYNAMIC_PAGE_TABLES][PTRS_PER_PMD];
static unsigned int __initdata next_early_pgt = 2;
pmdval_t early_pmd_flags = __PAGE_KERNEL_LARGE & ~(_PAGE_GLOBAL | _PAGE_NX);

/* Wipe all early page tables except for the kernel symbol map */
static void __init reset_early_page_tables(void)
{
	memset(early_level4_pgt, 0, sizeof(pgd_t)*(PTRS_PER_PGD-1));
	next_early_pgt = 0;
	write_cr3(__pa_nodebug(early_level4_pgt));
}

/* Create a new PMD entry */
int __init early_make_pgtable(unsigned long address)
{
	unsigned long physaddr = address - __PAGE_OFFSET;
	pgdval_t pgd, *pgd_p;
	pudval_t pud, *pud_p;
	pmdval_t pmd, *pmd_p;

	/* Invalid address or early pgt is done ?  */
	if (physaddr >= MAXMEM || read_cr3() != __pa_nodebug(early_level4_pgt))
		return -1;

again:
	pgd_p = &early_level4_pgt[pgd_index(address)].pgd;
	pgd = *pgd_p;

	/*
	 * The use of __START_KERNEL_map rather than __PAGE_OFFSET here is
	 * critical -- __PAGE_OFFSET would point us back into the dynamic
	 * range and we might end up looping forever...
	 */
	if (pgd)
		pud_p = (pudval_t *)((pgd & PTE_PFN_MASK) + __START_KERNEL_map - phys_base);
	else {
		if (next_early_pgt >= EARLY_DYNAMIC_PAGE_TABLES) {
			reset_early_page_tables();
			goto again;
		}

		pud_p = (pudval_t *)early_dynamic_pgts[next_early_pgt++];
		memset(pud_p, 0, sizeof(*pud_p) * PTRS_PER_PUD);
		*pgd_p = (pgdval_t)pud_p - __START_KERNEL_map + phys_base + _KERNPG_TABLE;
	}
	pud_p += pud_index(address);
	pud = *pud_p;

	if (pud)
		pmd_p = (pmdval_t *)((pud & PTE_PFN_MASK) + __START_KERNEL_map - phys_base);
	else {
		if (next_early_pgt >= EARLY_DYNAMIC_PAGE_TABLES) {
			reset_early_page_tables();
			goto again;
		}

		pmd_p = (pmdval_t *)early_dynamic_pgts[next_early_pgt++];
		memset(pmd_p, 0, sizeof(*pmd_p) * PTRS_PER_PMD);
		*pud_p = (pudval_t)pmd_p - __START_KERNEL_map + phys_base + _KERNPG_TABLE;
	}
	pmd = (physaddr & PMD_MASK) + early_pmd_flags;
	pmd_p[pmd_index(address)] = pmd;

	return 0;
}

/* Don't add a printk in there. printk relies on the PDA which is not initialized 
   yet. */
static void __init clear_bss(void)
{
	memset(__bss_start, 0,
	       (unsigned long) __bss_stop - (unsigned long) __bss_start);
}

static unsigned long get_cmd_line_ptr(void)
{
	unsigned long cmd_line_ptr = boot_params.hdr.cmd_line_ptr;

	cmd_line_ptr |= (u64)boot_params.ext_cmd_line_ptr << 32;

	return cmd_line_ptr;
}

/* The symbol table for a.out. */
struct multiboot_aout_symbol_table
{
  uint32_t tabsize;
  uint32_t strsize;
  uint32_t addr;
  uint32_t reserved;
};
typedef struct multiboot_aout_symbol_table multiboot_aout_symbol_table_t;

/* The section header table for ELF. */
struct multiboot_elf_section_header_table
{
  uint32_t num;
  uint32_t size;
  uint32_t addr;
  uint32_t shndx;
};
typedef struct multiboot_elf_section_header_table multiboot_elf_section_header_table_t;
struct multiboot_info
{
  /* Multiboot info version number */
  uint32_t flags;

  /* Available memory from BIOS */
  uint32_t mem_lower;
  uint32_t mem_upper;

  /* "root" partition */
  uint32_t boot_device;

  /* Kernel command line */
  uint32_t cmdline;

  /* Boot-Module list */
  uint32_t mods_count;
  uint32_t mods_addr;

  union
  {
    multiboot_aout_symbol_table_t aout_sym;
    multiboot_elf_section_header_table_t elf_sec;
  } u;

  /* Memory Mapping buffer */
  uint32_t mmap_length;
  uint32_t mmap_addr;

  /* Drive Info buffer */
  uint32_t drives_length;
  uint32_t drives_addr;

  /* ROM configuration table */
  uint32_t config_table;

  /* Boot Loader Name */
  uint32_t boot_loader_name;

  /* APM table */
  uint32_t apm_table;

  /* Video */
  uint32_t vbe_control_info;
  uint32_t vbe_mode_info;
  uint16_t vbe_mode;
  uint16_t vbe_interface_seg;
  uint16_t vbe_interface_off;
  uint16_t vbe_interface_len;

  uint64_t framebuffer_addr;
  uint32_t framebuffer_pitch;
  uint32_t framebuffer_width;
  uint32_t framebuffer_height;
  uint8_t framebuffer_bpp;
#define MULTIBOOT_FRAMEBUFFER_TYPE_INDEXED 0
#define MULTIBOOT_FRAMEBUFFER_TYPE_RGB     1
#define MULTIBOOT_FRAMEBUFFER_TYPE_EGA_TEXT     2
  uint8_t framebuffer_type;
  union
  {
    struct
    {
      uint32_t framebuffer_palette_addr;
      uint16_t framebuffer_palette_num_colors;
    };
    struct
    {
      uint8_t framebuffer_red_field_position;
      uint8_t framebuffer_red_mask_size;
      uint8_t framebuffer_green_field_position;
      uint8_t framebuffer_green_mask_size;
      uint8_t framebuffer_blue_field_position;
      uint8_t framebuffer_blue_mask_size;
    };
  };
};
struct multiboot_mmap_entry
{
  uint32_t size;
  uint64_t addr;
  uint64_t len;
#define MULTIBOOT_MEMORY_AVAILABLE              1
#define MULTIBOOT_MEMORY_RESERVED               2
#define MULTIBOOT_MEMORY_ACPI_RECLAIMABLE       3
#define MULTIBOOT_MEMORY_NVS                    4
#define MULTIBOOT_MEMORY_BADRAM                 5
  uint32_t type;
} __attribute__((packed));
typedef struct multiboot_mmap_entry multiboot_memory_map_t;
struct multiboot_mod_list
{
  /* the memory used goes from bytes 'mod_start' to 'mod_end-1' inclusive */
  uint32_t mod_start;
  uint32_t mod_end;

  /* Module command line */
  uint32_t cmdline;

  /* padding to take it to 16 bytes (must be zero) */
  uint32_t pad;
};
typedef struct multiboot_mod_list multiboot_module_t;

/* APM BIOS info. */
struct multiboot_apm_info
{
  uint16_t version;
  uint16_t cseg;
  uint32_t offset;
  uint16_t cseg_16;
  uint16_t dseg;
  uint16_t flags;
  uint16_t cseg_len;
  uint16_t cseg_16_len;
  uint16_t dseg_len;
};

static void __init multiboot_to_bootdata(char *real_mode_data)
{
	struct multiboot_info *info = (struct multiboot_info *) real_mode_data;
	//asm volatile ("1: jmp 1b");
	if (info->flags & 4)
	  boot_params.hdr.cmd_line_ptr = info->cmdline;
	boot_params.hdr.header = 0x53726448;
	boot_params.hdr.version = 0x020d;
	boot_params.hdr.type_of_loader = 0xb; /* qemu */
	boot_params.hdr.code32_start = 0x1000000;
	if (info->flags & (1 << 3) && info->mods_count) {
	    /* First module is the initrd */
	    multiboot_module_t *mod = __va(info->mods_addr);
	    boot_params.hdr.ramdisk_image = mod->mod_start;
	    boot_params.hdr.ramdisk_size = mod->mod_end - mod->mod_start;
	}
	boot_params.hdr.kernel_alignment = 0x200000;
	if (info->flags & (1 << 6)) {
	    int count;
	    multiboot_memory_map_t *mmap, *end;
	    mmap = __va(info->mmap_addr);
	    end = __va(info->mmap_addr + info->mmap_length);
	    for (count = 0; mmap < end && count < ARRAY_SIZE(boot_params.e820_map); mmap = (multiboot_memory_map_t *) ((uint64_t)mmap + mmap->size + sizeof(mmap->size)), count++) {
		boot_params.e820_map[count].addr = mmap->addr;
		boot_params.e820_map[count].size = mmap->len;
		boot_params.e820_map[count].type = mmap->type;
	    }
	    boot_params.e820_entries = count;
	}
}

static void __init copy_bootdata(char *real_mode_data)
{
	char * command_line;
	unsigned long cmd_line_ptr;

	if (((u64)real_mode_data) & 1)
	  multiboot_to_bootdata( (char*)(((u64)real_mode_data) - 1) );
	else
	  memcpy(&boot_params, real_mode_data, sizeof boot_params);
	sanitize_boot_params(&boot_params);
	cmd_line_ptr = get_cmd_line_ptr();
	if (cmd_line_ptr) {
		command_line = __va(cmd_line_ptr);
		memcpy(boot_command_line, command_line, COMMAND_LINE_SIZE);
	}
}

asmlinkage __visible void __init x86_64_start_kernel(char * real_mode_data)
{
	int i;

	/*
	 * Build-time sanity checks on the kernel image and module
	 * area mappings. (these are purely build-time and produce no code)
	 */
	BUILD_BUG_ON(MODULES_VADDR < __START_KERNEL_map);
	BUILD_BUG_ON(MODULES_VADDR - __START_KERNEL_map < KERNEL_IMAGE_SIZE);
	BUILD_BUG_ON(MODULES_LEN + KERNEL_IMAGE_SIZE > 2*PUD_SIZE);
	BUILD_BUG_ON((__START_KERNEL_map & ~PMD_MASK) != 0);
	BUILD_BUG_ON((MODULES_VADDR & ~PMD_MASK) != 0);
	BUILD_BUG_ON(!(MODULES_VADDR > __START_KERNEL));
	BUILD_BUG_ON(!(((MODULES_END - 1) & PGDIR_MASK) ==
				(__START_KERNEL & PGDIR_MASK)));
	BUILD_BUG_ON(__fix_to_virt(__end_of_fixed_addresses) <= MODULES_END);

	cr4_init_shadow();

	/* Kill off the identity-map trampoline */
	reset_early_page_tables();

	clear_bss();

	clear_page(init_level4_pgt);

	kasan_early_init();

	for (i = 0; i < NUM_EXCEPTION_VECTORS; i++)
		set_intr_gate(i, early_idt_handler_array[i]);
	load_idt((const struct desc_ptr *)&idt_descr);

	copy_bootdata(__va(real_mode_data));

	/*
	 * Load microcode early on BSP.
	 */
	load_ucode_bsp();

	/* set init_level4_pgt kernel high mapping*/
	init_level4_pgt[511] = early_level4_pgt[511];

	x86_64_start_reservations(real_mode_data);
}

void __init x86_64_start_reservations(char *real_mode_data)
{
	/* version is always not zero if it is copied */
	if (!boot_params.hdr.version)
		copy_bootdata(__va(real_mode_data));

	reserve_ebda_region();

	switch (boot_params.hdr.hardware_subarch) {
	case X86_SUBARCH_INTEL_MID:
		x86_intel_mid_early_setup();
		break;
	default:
		break;
	}

	start_kernel();
}
