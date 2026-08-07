# 微信滑动手势 Tweak —— rootless / ElleKit
# 模板参照已验证可编译的 WeChatNotifyFix（同为目标 com.tencent.xin 的 rootless 插件）
# + YukiPreventDelete 的健壮性 flag（ERROR_ON_WARNINGS=0 / internal logos 生成器）

export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = WeChat

export THEOS_PACKAGE_SCHEME = rootless
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = wechat_swipe_tweak

wechat_swipe_tweak_FILES = Tweak.xm
wechat_swipe_tweak_CFLAGS = -fobjc-arc -w
wechat_swipe_tweak_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
