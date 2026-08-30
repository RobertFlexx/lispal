# Security

Lispal tries to keep script memory away from raw host memory. Its `Pointer`
value is a checked runtime cell, not a machine address, and the standard library
does not expose arbitrary pointer arithmetic.

That does **not** make a Lispal runtime a security sandbox.

A script can still consume CPU with an infinite loop, allocate objects until the
host runs out of its chosen budget, and load Lispal units through configured
search paths. Any native function registered by an embedder has exactly the
authority the host gives it.

If you run code from people you do not trust, put normal process-level limits
around it (time, memory, filesystem/container permissions) instead of relying on
the VM as the security boundary.

The x86-64 Linux JIT writes code into writable pages and switches them to
read/execute before execution. It does not intentionally keep W+X mappings.

For a suspected memory-safety or JIT issue, please report the smallest
reproducer you can, including platform, Free Pascal version, JIT mode, and the
Lispal source that triggers it.
