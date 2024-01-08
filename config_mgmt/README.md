Config Management
===

We have a variety of linux kernel configs. We'd like to understand what options we're setting globally versus per architecture/endian/bitwidth.

To support this we add a wrapper around kernel builds where we allow configs to "#include" other config files.

The scripts in this directory are utilities for this process.

This implementation is limited. We don't recusrively expand includes.
