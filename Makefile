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
wechat_swipe_tweak_CFLAGS = -fobjc-arc -w -F$(THEOS_PROJECT_DIR)/Frameworks
# 关键：本设备 TrollFools 只加载“链接了 substrate(=ellekit)”的 tweak。
# 仿 WeChatX，链接设备自带的 CydiaSubstrate.framework 让 dylib 真正被加载。
# 注意：从设备拉回的 CydiaSubstrate 二进制 LINKEDIT 无余量，install_name_tool 无法改它的 id，
# 故 CI 改为在 make package 之后对“我们自己刚编译的 dylib”做
#   install_name_tool -change <原id> @executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
# 再重打包。这样运行时 loader 能在 app 的 Frameworks 里解析到 TrollFools 放的 ellekit。
wechat_swipe_tweak_LDFLAGS = -F$(THEOS_PROJECT_DIR)/Frameworks -framework CydiaSubstrate
wechat_swipe_tweak_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
