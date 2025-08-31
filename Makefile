EXTENSION = pg_scheduler
DATA = pg_scheduler--1.0.sql
MODULES = pg_scheduler
OBJS = pg_scheduler.o

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_scheduler
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
