# LMDB source

This directory vendors the unmodified library sources from OpenLDAP's
[LMDB 1.0.2 release](https://git.openldap.org/openldap/openldap/-/tree/LMDB_1.0.2/libraries/liblmdb),
commit `c279e0477c713076893e8c2b1a6337e421c15867`.
The OpenLDAP Public License and copyright notices are included in full.

Loam's optional native adapter compiles `mdb.c` and `midl.c`. Ordinary glowcap
networking and the portable Loam core do not link LMDB. Update the pinned
sources together and rerun the Loam backend and crash tests.

The native backend uses the LMDB 1.x disk format. Existing 0.9 databases
are not supported; use a fresh Loam database directory.
