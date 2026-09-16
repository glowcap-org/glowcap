# LMDB source

This directory vendors the unmodified library sources from OpenLDAP's
[LMDB 0.9.36 release](https://git.openldap.org/openldap/openldap/-/tree/LMDB_0.9.36/libraries/liblmdb),
commit `028f61b6832032174f893484719ed4848d8d60db`.
The OpenLDAP Public License and copyright notices are included in full.

Loam's optional native adapter compiles `mdb.c` and `midl.c`. Ordinary glowcap
networking and the portable Loam core do not link LMDB. Update the pinned
sources together and rerun the Loam backend and crash tests.
