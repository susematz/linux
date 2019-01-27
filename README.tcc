This v4.6 kernel can be compiled with TCC.  Provided are
three configs that are known to work: knownok.config, knownok2.config,
smaller.config.  Provided is also a script to create a small initrd
for testing.

First build TCC somewhere, you don't have to install it which makes
hacking easier.  Some parts of the kernel can't (yet) be build
with TCC, in particular the 16bit startup code.  Due to some support
lacking in the assembler support not all .S files can be build
either.  Some .S file could be build, but to make live easy right
now all of them are simply build by gcc.

Due to this there are two compilers involved which are stored
in make variables CC (defaulting to gcc) and REALCC (defaulting
to $(CC)).  The normal .c sources of the kernel are build with $(REALCC),
so that's the one you'd override with tcc.

Linking is also still done with gcc (i.e. with whatever is the default
link editor for that).  TCC still lacks some support for this as well.

Let's start with a relatively complete and known working config:

% make knownok.config

First check if the kernel works when compiled without tcc:

% make -j8

We'll use qemu for testing, and we need an initrd.  If you don't
have one around, you can create a simple one:

% ./tcc/create_initrd

(puts a cpio based initrd in ./tcc/initrd/cpio)
Now we check if everything works:

% qemu-system-x86_64 -s -m 1024 -serial vc -debugcon vc -kernel arch/x86/boot/bzImage -append "console=ttyS0,vga earlycon=uart,io,0xe9 earlyprintk=vga" -initrd tcc/initrd/cpio

If you used the above small initrd when you exit the shell it's automatically
call poweroff.  The above options to qemu enable debug and normal
console, and early bootup messages.

That should have worked, now we test with tcc:

% make clean
% TCCDIR=/path/to/tinycc
% make REALCC="$TCCDIR/tcc -B$TCCDIR" CCLIB="$TCCDIR/libtcc1.a" -j8

Repeat the qemu command and it should still work, just slower.

You can use smaller configs, knownok2.config and smaller.config
(see arch/x86/config/).

This kernel also has a multiboot header and the necessary bootup glue code
to make it loadable within qemu.  That obviates the need to compress and
repack the kernel into a bzImage, you can directly load the vmlinux ELF
file.  If your qemu supports it, then, just make vmlinux:

% make REALCC="$TCCDIR/tcc -B$TCCDIR" CCLIB="$TCCDIR/libtcc1.a" vmlinux -j8

and use 'vmlinux' as kernel argument for qemu:

% qemu-system-x86_64 -s -m 1024 -serial vc -debugcon vc -kernel vmlinux -append "console=ttyS0,vga earlycon=uart,io,0xe9 earlyprintk=vga" -initrd tcc/initrd/cpio

If your qemu throws errors about inconsistencies in the multiboot
header you might look into tcc/qemu.diff for changes that I needed
for some qemu versions (it disables a consistency check that actually
tests for something that isn't specified in this way in the multiboot
spec).
