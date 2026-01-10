KERNEL_RELEASE  ?= $(shell uname -r)
KERNEL_DIR      ?= /lib/modules/$(KERNEL_RELEASE)/build
DKMS_TARBALL    ?= dkms.tar.gz
TAR             ?= tar

# 默认构建监控模块
obj-m           += lotmonitor.o


ccflags-y := -std=gnu99

.PHONY: all clean load unload monitor speed
.PHONY: .always-make

all: monitor

# 构建监控模块
monitor:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) obj-m=lotmonitor.o modules

clean: clean-dkms.conf clean-dkms-tarball
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) clean

# 加载监控模块
load:
	sudo insmod lotmonitor.ko

# 卸载监控模块
unload:
	-sudo rmmod lotmonitor 2>/dev/null || true

# 重新加载
reload: unload load

# 查看统计
stats:
	cat /proc/lotmonitor/stats

# 查看连接
conns:
	cat /proc/lotmonitor/conns

# 查看样本
samples:
	cat /proc/lotmonitor/samples

.PHONY: dkms-tarball clean-dkms-tarball clean-dkms.conf

.always.make:

dkms.conf: ./scripts/mkdkmsconf.sh .always-make
	./scripts/mkdkmsconf.sh > dkms.conf

clean-dkms.conf:
	$(RM) dkms.conf

$(DKMS_TARBALL): dkms.conf Makefile lotmonitor.c
	$(TAR) zcf $(DKMS_TARBALL) \
		--transform 's,^,./dkms_source_tree/,' \
		dkms.conf \
		Makefile \
		lotmonitor.c

dkms-tarball: $(DKMS_TARBALL)

clean-dkms-tarball:
	$(RM) $(DKMS_TARBALL)
