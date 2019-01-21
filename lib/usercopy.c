#include <linux/export.h>
#include <linux/bug.h>
#include <linux/uaccess.h>

void copy_from_user_overflow(void)
{
	WARN(1, "Buffer overflow detected!\n");
}
EXPORT_SYMBOL(copy_from_user_overflow);

#ifdef __TINYC__
/* TCC can't remove dead code, so references to all the
   "don't call this" symbols remain.  Provide implementations
   that bug at runtime.  */
#define PROVIDE_BAD(rettype, name) \
extern rettype name (void);  \
rettype name (void) \
{ \
  BUG(); \
} \
EXPORT_SYMBOL(name)
PROVIDE_BAD(void, __bad_percpu_size);
PROVIDE_BAD(void, __xchg_wrong_size);
PROVIDE_BAD(void, __xadd_wrong_size);
PROVIDE_BAD(void, __cmpxchg_wrong_size);
PROVIDE_BAD(int, __get_user_bad);
PROVIDE_BAD(void, __put_user_bad);
PROVIDE_BAD(void, __bad_size_call_parameter);
PROVIDE_BAD(void, __compiletime_assert_0);
PROVIDE_BAD(void, __bad_unaligned_access_size);
PROVIDE_BAD(void, __put_user_X);
PROVIDE_BAD(void, __bad_ndelay);
PROVIDE_BAD(void, __bad_udelay);
/* For libtcc1.a's __va_arg: */
PROVIDE_BAD(void, abort);

/* Some things were TCC can't optimize yet: */
PROVIDE_BAD(void, ext4_decrypt);
PROVIDE_BAD(void, ext4_encrypt);
PROVIDE_BAD(int, ext4_inherit_context);
PROVIDE_BAD(void, ext4_restore_control_page);
PROVIDE_BAD(void, ext4_fname_encrypted_size);
PROVIDE_BAD(void, ext4_fname_usr_to_disk);
PROVIDE_BAD(void, ext4_encrypted_symlink_inode_operations);
PROVIDE_BAD(void, ext4_read_workqueue);
PROVIDE_BAD(void, ext4_release_crypto_ctx);

PROVIDE_BAD(void, move_huge_pmd);
PROVIDE_BAD(void, do_huge_pmd_anonymous_page);
PROVIDE_BAD(void, do_huge_pmd_wp_page);
PROVIDE_BAD(void, dax_writeback_mapping_range);
PROVIDE_BAD(void, pmdp_test_and_clear_young);

#if !(defined CONFIG_X86_32 || defined CONFIG_IA32_EMULATION)
PROVIDE_BAD(void, convert_from_fxsr);
PROVIDE_BAD(void, convert_to_fxsr);
#endif

int __builtin_ctzll(long long val)
{
  int num;
  if (!val) return 64;
  while (!(val & 1)) {
      val >>= 1;
      num++;
  }
  return num;
}
#endif
