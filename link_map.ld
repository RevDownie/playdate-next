/* The SDK's buildsupport/link_map.ld with every section padded to a 32 byte boundary (the largest alignment in the
   game: cache line aligned arrays) so the sections are back to back. pdc packs .text and .data together and sizes
   the game's memory as the sum of the section sizes, ignoring any alignment gap between them: with a gap, the end
   of .bss lay outside the memory the loader reserves, the OS heap handed it out, and its block headers overwrote
   our last globals (the HUD's font pointers) the first time the OS allocated, e.g. on the lock screen.
   Its GROUP(libgcc.a libc.a libm.a) is gone: build.zig passes those archives to the link itself */
ENTRY(eventHandlerShim)

SECTIONS
{
	.text :
	{
		*(.text)
		*(.text.*)

		KEEP(*(.init))
		KEEP(*(.fini))

		/* .ctors */
		*crtbegin.o(.ctors)
		*crtbegin?.o(.ctors)
		*(EXCLUDE_FILE(*crtend?.o *crtend.o) .ctors)
		*(SORT(.ctors.*))
		*(.ctors)

		/* .dtors */
 		*crtbegin.o(.dtors)
 		*crtbegin?.o(.dtors)
 		*(EXCLUDE_FILE(*crtend?.o *crtend.o) .dtors)
 		*(SORT(.dtors.*))
 		*(.dtors)

		*(.rodata*)

		KEEP(*(.eh_frame*))

		. = ALIGN(32);

	}

	.data :
	{
		__etext = .;

		__data_start__ = .;
		*(vtable)
		*(.data*)

		. = ALIGN(4);
		/* preinit data */
		PROVIDE_HIDDEN (__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN (__preinit_array_end = .);

		. = ALIGN(4);
		/* init data */
		PROVIDE_HIDDEN (__init_array_start = .);
		KEEP(*(SORT(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN (__init_array_end = .);

		. = ALIGN(4);
		/* finit data */
		PROVIDE_HIDDEN (__fini_array_start = .);
		KEEP(*(SORT(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN (__fini_array_end = .);

		. = ALIGN(32);
		/* All data end */
		__data_end__ = .;

	}

	.bss :
	{
		. = ALIGN(4);
		__bss_start__ = .;
		*(.bss*)
		*(COMMON)
		*(COM)
		. = ALIGN(4);
		__bss_end__ = .;

	}

  /DISCARD/ :
  {
		*(.ARM.exidx)
  }

}

/* What pdc assumes (see the top): no gaps, so the memory it reserves covers all of .bss */
ASSERT(ADDR(.data) == ADDR(.text) + SIZEOF(.text), "gap between .text and .data: pdc would reserve too little memory")
ASSERT(ADDR(.bss) == ADDR(.data) + SIZEOF(.data), "gap between .data and .bss: pdc would reserve too little memory")
