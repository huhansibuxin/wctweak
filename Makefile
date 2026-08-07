ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = wechat_swipe_tweak

wechat_swipe_tweak_FILES = Tweak.xm
wechat_swipe_tweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
wechat_swipe_tweak_FRAMEWORKS = UIKit Foundation
wechat_swipe_tweak_PRIVATE_FRAMEWORKS = UICore
wechat_swipe_tweak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

# 打包命令
after-package::
	@echo ""
	@echo "============================================"
	@echo "  打包完成: $(THEOS_PACKAGE_DIR)/$(PACKAGE_FILENAME)"
	@echo "  安装方式:"
	@echo "    TrollFools: 直接注入 .deb 或提取 dylib"
	@echo "    dpkg -i $(THEOS_PACKAGE_DIR)/$(PACKAGE_FILENAME)"
	@echo "  日志查看: cat /var/mobile/Library/Preferences/com.boss.swipetweak.log"
	@echo "============================================"
