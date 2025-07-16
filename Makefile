# Windows Makefile for pg_scheduler
EXTENSION = pg_scheduler
MODULE_big = pg_scheduler
OBJS = pg_scheduler.obj
PG_CPPFLAGS = -I"$(shell pg_config --includedir-server)" -I"$(shell pg_config --includedir)"
SHLIB_LINK = -L"$(shell pg_config --libdir)" -lws2_32

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)