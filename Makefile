KERNEL_RELEASE  ?= $(shell uname -r)
KERNEL_DIR      ?= /lib/modules/$(KERNEL_RELEASE)/build
DKMS_TARBALL    ?= dkms.tar.gz
TAR             ?= tar
PYTHON          ?= python3

# 默认构建监控模块
obj-m           += lotmonitor.o


ccflags-y := -std=gnu99

.PHONY: all clean load unload monitor speed
.PHONY: .always-make
.PHONY: collect train control status install-deps

all: monitor

# 构建监控模块
monitor:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) obj-m=lotmonitor.o modules

clean: clean-dkms.conf clean-dkms-tarball
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) clean
	rm -rf mdp_data/*.pth mdp_data/*.json mdp_data/*.csv __pycache__

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

# 查看控制状态
control-status:
	cat /proc/lotmonitor/control

# =============================================================================
# Python 工作流
# =============================================================================

# 安装 Python 依赖
install-deps:
	pip3 install -r requirements.txt

# 采集数据 (60秒)
collect:
	$(PYTHON) collector.py collect --duration 60

# 采集数据 (长时间)
collect-long:
	$(PYTHON) collector.py collect --duration 600

# 分析采集的数据
analyze:
	$(PYTHON) collector.py analyze

# 实时监控
monitor-live:
	$(PYTHON) collector.py monitor

# 训练模型
train:
	$(PYTHON) trainer.py train --episodes 500

# 快速训练
train-quick:
	$(PYTHON) trainer.py train --episodes 100

# 评估模型
evaluate:
	$(PYTHON) trainer.py evaluate

# 导出策略表
export-policy:
	$(PYTHON) trainer.py export

# 启动控制器
control:
	sudo $(PYTHON) controller.py start --interactive

# 停止控制
control-stop:
	sudo $(PYTHON) controller.py stop

# =============================================================================
# 完整工作流
# =============================================================================

# 完整训练流程: 采集 -> 训练 -> 评估
workflow: collect train evaluate export-policy
	@echo "训练工作流完成!"

# 部署: 加载模块 + 启动控制器
deploy: load
	@echo "等待模块初始化..."
	sleep 2
	sudo $(PYTHON) controller.py start

# =============================================================================
# DKMS
# =============================================================================

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

# =============================================================================
# 帮助
# =============================================================================

help:
	@echo "LotMonitor - 智能 TCP 拥塞控制系统"
	@echo ""
	@echo "内核模块:"
	@echo "  make monitor      - 编译内核模块"
	@echo "  make load         - 加载模块"
	@echo "  make unload       - 卸载模块"
	@echo "  make reload       - 重新加载"
	@echo "  make stats        - 查看统计"
	@echo "  make conns        - 查看连接"
	@echo "  make samples      - 查看样本"
	@echo ""
	@echo "Python 工作流:"
	@echo "  make install-deps - 安装依赖"
	@echo "  make collect      - 采集数据 (60秒)"
	@echo "  make analyze      - 分析数据"
	@echo "  make train        - 训练模型"
	@echo "  make evaluate     - 评估模型"
	@echo "  make control      - 启动控制器"
	@echo ""
	@echo "完整流程:"
	@echo "  make workflow     - 采集 -> 训练 -> 评估"
	@echo "  make deploy       - 加载模块 + 启动控制器"
