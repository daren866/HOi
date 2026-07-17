<#
.SYNOPSIS
ArkUI-X 项目依赖克隆脚本

.DESCRIPTION
克隆完整的 ArkUI-X 项目依赖，包括核心引擎、应用框架、构建工具等。
当前项目仅包含 iOS 平台适配层，需要克隆完整依赖才能编译。
#>

$ErrorActionPreference = "Stop"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "       ArkUI-X 项目依赖克隆脚本" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

$ROOT_DIR = Get-Location
Write-Host "当前工作目录: $ROOT_DIR"
Write-Host ""

function Clone-Repo {
    param(
        [string]$repoUrl,
        [string]$targetDir,
        [string]$displayName
    )
    
    Write-Host "正在克隆: $displayName" -ForegroundColor Yellow
    Write-Host "  URL: $repoUrl"
    Write-Host "  目标: $targetDir"
    
    if (Test-Path $targetDir) {
        Write-Host "  目录已存在，跳过..." -ForegroundColor Gray
        Write-Host ""
        return
    }
    
    try {
        git clone $repoUrl $targetDir
        Write-Host "  克隆完成!" -ForegroundColor Green
    }
    catch {
        Write-Host "  克隆失败: $_" -ForegroundColor Red
    }
    
    Write-Host ""
}

New-Item -ItemType Directory -Path "foundation/arkui/ace_engine/adapter" -Force | Out-Null

Write-Host "[1/14] 克隆核心依赖..." -ForegroundColor Cyan

Clone-Repo -repoUrl "https://gitee.com/openharmony/arkui_ace_engine.git" `
           -targetDir "$ROOT_DIR/foundation/arkui/ace_engine" `
           -displayName "ArkUI引擎核心 (ace_engine)"

Clone-Repo -repoUrl "https://gitee.com/arkui-x/app_framework.git" `
           -targetDir "$ROOT_DIR/foundation/appframework" `
           -displayName "应用框架兼容适配层"

Clone-Repo -repoUrl "https://gitee.com/openharmony/arkui_napi.git" `
           -targetDir "$ROOT_DIR/foundation/arkui/napi" `
           -displayName "Native API扩展机制"

Clone-Repo -repoUrl "https://gitee.com/openharmony/build.git" `
           -targetDir "$ROOT_DIR/build_openharmony" `
           -displayName "构建配置脚本"

Clone-Repo -repoUrl "https://gitee.com/arkui-x/build_plugins.git" `
           -targetDir "$ROOT_DIR/build_plugins" `
           -displayName "跨平台构建插件"

Clone-Repo -repoUrl "https://gitee.com/arkui-x/samples.git" `
           -targetDir "$ROOT_DIR/samples" `
           -displayName "示例代码"

Write-Host "[2/14] 克隆基础库..." -ForegroundColor Cyan

Clone-Repo -repoUrl "https://gitee.com/openharmony/commonlibrary_c_utils.git" `
           -targetDir "$ROOT_DIR/commonlibrary/c_utils" `
           -displayName "通用C++功能库"

Clone-Repo -repoUrl "https://gitee.com/openharmony/hiviewdfx_hilog.git" `
           -targetDir "$ROOT_DIR/base/hiviewdfx/hilog" `
           -displayName "系统日志功能"

Write-Host "[3/14] 克隆服务层依赖..." -ForegroundColor Cyan

Clone-Repo -repoUrl "https://gitee.com/openharmony/communication_netmanager_base.git" `
           -targetDir "$ROOT_DIR/foundation/communication/netmanager_base" `
           -displayName "网络管理模块"

Clone-Repo -repoUrl "https://gitee.com/openharmony/graphic_graphic_2d.git" `
           -targetDir "$ROOT_DIR/foundation/graphic/graphic_2d" `
           -displayName "2D图形基础库"

Clone-Repo -repoUrl "https://gitee.com/openharmony/filemanagement_file_api.git" `
           -targetDir "$ROOT_DIR/foundation/filemanagement/file_api" `
           -displayName "文件API"

Clone-Repo -repoUrl "https://gitee.com/openharmony/multimedia_image_framework.git" `
           -targetDir "$ROOT_DIR/foundation/multimedia/image_framework" `
           -displayName "图片编解码"

Write-Host "[4/14] 克隆编译器依赖..." -ForegroundColor Cyan

Clone-Repo -repoUrl "https://gitee.com/openharmony/arkcompiler_ets_runtime.git" `
           -targetDir "$ROOT_DIR/arkcompiler/ets_runtime" `
           -displayName "ArkTS运行时"

Clone-Repo -repoUrl "https://gitee.com/openharmony/arkcompiler_runtime_core.git" `
           -targetDir "$ROOT_DIR/arkcompiler/runtime_core" `
           -displayName "编译器运行时核心"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  核心依赖克隆完成!" -ForegroundColor Green
Write-Host ""
Write-Host "  目录结构:" -ForegroundColor Yellow
Write-Host "  ├── build_openharmony/           (构建配置)"
Write-Host "  ├── build_plugins/               (跨平台构建插件)"
Write-Host "  ├── foundation/"
Write-Host "  │   ├── arkui/ace_engine/          (核心引擎)"
Write-Host "  │   ├── arkui/napi/                 (NAPI扩展)"
Write-Host "  │   ├── appframework/               (应用框架)"
Write-Host "  │   ├── communication/netmanager_base/"
Write-Host "  │   ├── graphic/graphic_2d/"
Write-Host "  │   ├── filemanagement/file_api/"
Write-Host "  │   └── multimedia/image_framework/"
Write-Host "  ├── arkcompiler/"
Write-Host "  ├── commonlibrary/c_utils/"
Write-Host "  ├── base/hiviewdfx/hilog/"
Write-Host "  └── samples/"
Write-Host ""
Write-Host "  下一步操作:" -ForegroundColor Yellow
Write-Host "  1. 配置编译环境 (Python 3.8+, Node.js, Xcode)"
Write-Host "  2. 执行构建命令生成 libarkui_ios.a 静态库"
Write-Host "  3. 将生成的库集成到 ArkUIPlayer 项目"
Write-Host "================================================" -ForegroundColor Cyan