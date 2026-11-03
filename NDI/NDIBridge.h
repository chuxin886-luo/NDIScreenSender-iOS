//
//  NDIBridge.h
//  把 NDI SDK（Objective-C / C）暴露给 Swift
//
//  只有定义了 NDI_ENABLED 时才会真正引入 NDI 头文件。
//  走 UDP 模式、不想装 NDI SDK 的话，把 project.yml 里的
//    GCC_PREPROCESSOR_DEFINITIONS / SWIFT_ACTIVE_COMPILATION_CONDITIONS 中的
//    NDI_ENABLED 去掉，并注释掉 NDI xcframework 依赖即可，头文件不会报错。
//
#ifndef NDIBridge_h
#define NDIBridge_h

#ifdef NDI_ENABLED
#include "Processing.NDI.Lib.h"
#endif

#endif /* NDIBridge_h */
