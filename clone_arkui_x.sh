#!/bin/bash

set -e

echo "================================================"
echo "       ArkUI-X 项目依赖克隆脚本"
echo "================================================"
echo ""

ROOT_DIR=$(pwd)
echo "当前工作目录: $ROOT_DIR"
echo ""

clone_repo() {
    local repo_url=$1
    local target_dir=$2
    local display_name=$3
    
    echo "正在克隆: $display_name"
    echo "  URL: $repo_url"
    echo "  目标: $target_dir"
    
    if [ -d "$target_dir" ]; then
        echo "  目录已存在，跳过..."
        echo ""
        return
    fi
    
    git clone "$repo_url" "$target_dir"
    echo "  克隆完成!"
    echo ""
}

mkdir -p foundation/arkui/ace_engine/adapter

clone_repo "https://gitee.com/openharmony/arkui_ace_engine.git" \
           "$ROOT_DIR/foundation/arkui/ace_engine" \
           "ArkUI引擎核心 (ace_engine)"

clone_repo "https://gitee.com/arkui-x/app_framework.git" \
           "$ROOT_DIR/foundation/appframework" \
           "应用框架兼容适配层"

clone_repo "https://gitee.com/openharmony/arkui_napi.git" \
           "$ROOT_DIR/foundation/arkui/napi" \
           "Native API扩展机制"

clone_repo "https://gitee.com/openharmony/build.git" \
           "$ROOT_DIR/build" \
           "构建配置脚本"

clone_repo "https://gitee.com/arkui-x/build_plugins.git" \
           "$ROOT_DIR/build_plugins" \
           "跨平台构建插件"

clone_repo "https://gitee.com/arkui-x/samples.git" \
           "$ROOT_DIR/samples" \
           "示例代码"

clone_repo "https://gitee.com/openharmony/commonlibrary_c_utils.git" \
           "$ROOT_DIR/commonlibrary/c_utils" \
           "通用C++功能库"

clone_repo "https://gitee.com/openharmony/hiviewdfx_hilog.git" \
           "$ROOT_DIR/base/hiviewdfx/hilog" \
           "系统日志功能"

clone_repo "https://gitee.com/openharmony/communication_netmanager_base.git" \
           "$ROOT_DIR/foundation/communication/netmanager_base" \
           "网络管理模块"

clone_repo "https://gitee.com/openharmony/graphic_graphic_2d.git" \
           "$ROOT_DIR/foundation/graphic/graphic_2d" \
           "2D图形基础库"

clone_repo "https://gitee.com/openharmony/filemanagement_file_api.git" \
           "$ROOT_DIR/foundation/filemanagement/file_api" \
           "文件API"

clone_repo "https://gitee.com/openharmony/multimedia_image_framework.git" \
           "$ROOT_DIR/foundation/multimedia/image_framework" \
           "图片编解码"

clone_repo "https://gitee.com/openharmony/arkcompiler_ets_runtime.git" \
           "$ROOT_DIR/arkcompiler/ets_runtime" \
           "ArkTS运行时"

clone_repo "https://gitee.com/openharmony/arkcompiler_runtime_core.git" \
           "$ROOT_DIR/arkcompiler/runtime_core" \
           "编译器运行时核心"

clone_repo "https://gitee.com/openharmony/developtools_ace_ets2bundle.git" \
           "$ROOT_DIR/developtools/ace_ets2bundle" \
           "ETS编译工具"

echo "================================================"
echo "  核心依赖克隆完成!"
echo ""
echo "  目录结构:"
echo "  ├── build/"
echo "  ├── build_plugins/"
echo "  ├── foundation/"
echo "  │   ├── arkui/ace_engine/          (核心引擎)"
echo "  │   ├── arkui/napi/                 (NAPI扩展)"
echo "  │   ├── appframework/               (应用框架)"
echo "  │   ├── communication/netmanager_base/"
echo "  │   ├── graphic/graphic_2d/"
echo "  │   ├── filemanagement/file_api/"
echo "  │   └── multimedia/image_framework/"
echo "  ├── arkcompiler/"
echo "  ├── commonlibrary/c_utils/"
echo "  ├── base/hiviewdfx/hilog/"
echo "  └── samples/"
echo ""
echo "  接下来请执行: ./build/arkui/build_ios.sh (需要配置完整构建环境)"
echo "================================================"