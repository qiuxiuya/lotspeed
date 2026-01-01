KERNEL_RELEASE  ?= $(shell uname -r)
KERNEL_DIR      ?= /lib/modules/$(KERNEL_RELEASE)/build
DKMS_TARBALL    ?= dkms.tar.gz
TAR             ?= tar
obj-m           += lotspeed.o

ccflags-y := -std=gnu99

.PHONY: all clean load unload v1
.PHONY: .always-make

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules

clean: clean-dkms.conf clean-dkms-tarball
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) clean

load:
	sudo insmod lotspeed.ko

unload:
	sudo rmmod lotspeed

.PHONY: dkms-tarball clean-dkms-tarball clean-dkms.conf

.always.make:

dkms.conf: ./scripts/mkdkmsconf.sh .always-make
	./scripts/mkdkmsconf.sh > dkms.conf

clean-dkms.conf:
	$(RM) dkms.conf

$(DKMS_TARBALL): dkms.conf Makefile lotspeed.c
	$(TAR) zcf $(DKMS_TARBALL) \
		--transform 's,^,./dkms_source_tree/,' \
		dkms.conf \
		Makefile \
		lotspeed.c

dkms-tarball: $(DKMS_TARBALL)

clean-dkms-tarball:
	$(RM) $(DKMS_TARBALL)
