; ============================================================
; DeskDrawer.ahk — 融入桌面的桌面抽屉（AutoHotkey v2）
; 版本：2026-11-16 原始样式版（GDI+ 预渲染面板背景，默认原始样式，毛玻璃可切换；已修退出崩溃）
; ============================================================
; 设计来源：桌面管理器设计页（全屏桌面 + 分区 + 系统分区）
;   原始效果：轻透面板 + 壁纸原样透出；毛玻璃为风格开关，默认关闭
;
; 运行要求：
;   AutoHotkey v2.0.31+（AutoHotkey64.exe 便携版即可，无需安装，
;   不需要 .NET / Java），Windows 10 / 11
;   双击运行；Esc 或点「隐藏」收起抽屉；Win+Alt+D 再次呼出；
;   托盘图标右键可退出。分区移动记录保存在同目录 DeskDrawer.ini
;
; 实现要点（相对设计页的映射）：
;   全屏桌面   -> 一个无边框置顶 Gui（+AlwaysOnTop -Caption +ToolWindow），
;                  尺寸取主显示器工作区，系统任务栏保持可见
;   壁纸背景   -> 注册表读取当前壁纸，全屏 Picture 铺底
;   分区面板   -> baked 进 GDI+ 背景图（原始样式 / 毛玻璃两种），失败时才用 Text 底色块
;   真实图标   -> SHGetFileInfoW 取 HICON，Picture 控件 "HICON:" 显示
;   回收站/此电脑 -> CLSID 解析名取图标，explorer shell:::{...} 打开
;   毛玻璃开关 -> GDI+ 预渲染面板背景图，默认关闭（原始样式：壁纸 + 轻透面板）；
;                  打开时面板里的壁纸换成模糊版（毛玻璃效果）；
;                  合成失败时回退到 DWM ACCENT_ENABLE_BLURBEHIND 模糊
;   时钟小组件 -> FormatTime + SetTimer 每秒刷新（天气未接入）
;   翻页       -> 按钮 + Gui.Destroy() 重建
;   拖拽换分区 -> OnMessage(WM_LBUTTONDOWN) 跟踪鼠标，松手落点判定分区
;
; 样式说明：AHK 原生控件是经典 Win32 外观，没有圆角/阴影/半透明；
;   文字控件默认带白底，须加 BackgroundTrans 才能浮在壁纸/面板上；
;   分区不用 GroupBox（太像系统对话框），改用面板 + 蓝色标题 + 细分隔线；
;   面板样式是 GDI+ 预渲染的整屏背景图（壁纸 + 轻透面板 baked 进去，
;   毛玻璃只是把面板里的壁纸换成模糊版），不是逐块亚克力；
;   按钮仍是原生 Win32 外观。
; ============================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent(true)

; ---------------- 配置 ----------------
global gIniFile   := A_ScriptDir . "\DeskDrawer.ini"
global gZoneNames := ["系统", "常用应用", "文档", "图片与媒体", "文件夹", "待整理"]
global gExtApps   := Map("lnk", 1, "exe", 1, "url", 1, "bat", 1, "cmd", 1)
global gExtDocs   := Map("txt", 1, "doc", 1, "docx", 1, "pdf", 1, "xls", 1, "xlsx", 1, "ppt", 1, "pptx", 1, "md", 1, "rtf", 1, "csv", 1)
global gExtMedia  := Map("png", 1, "jpg", 1, "jpeg", 1, "gif", 1, "bmp", 1, "webp", 1, "ico", 1, "mp4", 1, "mp3", 1, "wav", 1, "mkv", 1, "mov", 1, "avi", 1, "flac", 1)
global gIconSizes := [32, 48, 64]

; ---------------- 状态 ----------------
; AHK v2 作用域规则：函数内只要给变量赋值，它就是局部变量；
; 想读写全局变量，必须在函数内声明 global。只读的变量可直接用全局的。
; 下面每个会改全局变量的函数，开头都有一行 global 声明。
global gGui           := ""    ; 主 Gui 对象
global gItems         := []    ; 桌面项：Map 数组 {name, path, clsid, isDir, ext, special, zone}
global gIcons         := []    ; 本次建窗取到的 HICON，销毁窗口时统一 DestroyIcon
global gIconHwnds     := Map() ; 控件句柄 -> {item, pic, lbl}，用于拖拽与搜索过滤
global gZoneRects     := []    ; 分区矩形（相对 Gui 的客户区坐标），用于落点判定
global gGlass         := false ; 毛玻璃开关，默认关闭（原始效果）
global gIconSize      := 48
global gPage          := 1
global gTotalPages    := 1
global gPerZone       := 12
global gSearch        := ""
global gClockCtrl     := ""
global gDateCtrl      := ""
global gPageText      := ""
global gStatusCtrl    := ""
global gDragging      := false
global gDrag          := ""
global gSuppressClick := 0

; ---------------- 图标：SHGetFileInfoW 取 HICON ----------------
GetIcon(item) {
    path := item.clsid != "" ? item.clsid : item.path
    sfi := Buffer(696, 0)  ; SHFILEINFO（x64）：hIcon 8 + iIcon 4 + dwAttr 4 + 520 + 160
    DllCall("shell32\SHGetFileInfoW", "Str", path, "UInt", 0, "Ptr", sfi, "UInt", sfi.Size, "UInt", 0x100)  ; 0x100 = SHGFI_ICON
    hIcon := NumGet(sfi, 0, "Ptr")
    if (hIcon = 0) {
        ; 兜底：取桌面文件夹图标
        sfi2 := Buffer(696, 0)
        DllCall("shell32\SHGetFileInfoW", "Str", A_Desktop, "UInt", 0, "Ptr", sfi2, "UInt", sfi2.Size, "UInt", 0x100)
        hIcon := NumGet(sfi2, 0, "Ptr")
    }
    return hIcon
}

; ---------------- 分类与持久化 ----------------
Classify(name, ext, isDir) {
    if (isDir)
        return "文件夹"
    if (gExtApps.Has(ext))
        return "常用应用"
    if (gExtDocs.Has(ext))
        return "文档"
    if (gExtMedia.Has(ext))
        return "图片与媒体"
    return "待整理"
}

ItemKey(item) {
    if (item.special = "recycle")
        return "RecycleBin"
    if (item.special = "computer")
        return "ThisPC"
    return item.name
}

GetSavedZone(item, defaultZone) {
    saved := IniRead(gIniFile, "Zones", ItemKey(item), "")
    return saved != "" ? saved : defaultZone
}

SetItemZone(item, zone) {
    item.zone := zone
    IniWrite(zone, gIniFile, "Zones", ItemKey(item))
}

LoadSettings() {
    global gGlass, gIconSize, gIniFile
    gGlass := IniRead(gIniFile, "Settings", "Glass", "0") = "1"
    size := Integer(IniRead(gIniFile, "Settings", "IconSize", "48"))
    gIconSize := (size = 32 || size = 48 || size = 64) ? size : 48
}

SaveSettings() {
    IniWrite(gGlass ? "1" : "0", gIniFile, "Settings", "Glass")
    IniWrite(String(gIconSize), gIniFile, "Settings", "IconSize")
}

; ---------------- 毛玻璃：DWM 模糊 ----------------
; AHK v2 的 Gui 没有原生亚克力；这里用未公开的
; SetWindowCompositionAttribute 开 ACCENT_ENABLE_BLURBEHIND，
; 让窗口背景由 DWM 模糊身后的真实桌面。
; 注意：系统「设置 > 个性化 > 颜色 > 透明效果」关闭时模糊可能不生效，
; 此时开关仍会切换面板配色，视觉上仍有变化。
EnableBlur(hwnd, enable) {
    accent := Buffer(16, 0)  ; ACCENT_POLICY：状态 / 标志 / 颜色 / 动画
    NumPut("Int", enable ? 3 : 0, accent, 0)   ; 3 = ACCENT_ENABLE_BLURBEHIND，0 = 禁用
    NumPut("Int", 0, accent, 4)
    NumPut("UInt", 0, accent, 8)
    NumPut("Int", 0, accent, 12)
    data := Buffer(24, 0)    ; WINCOMPATTRDATA（x64）：属性 4 + 填充 4 + 指针 8 + 长度 4 + 填充 4
    NumPut("Int", 19, data, 0)              ; 19 = WCA_ACCENT_POLICY
    NumPut("Ptr", accent.Ptr, data, 8)
    NumPut("UInt", 16, data, 16)
    DllCall("user32\SetWindowCompositionAttribute", "Ptr", hwnd, "Ptr", data)
}

GetWallpaper() {
    try {
        wp := RegRead("HKCU\Control Panel\Desktop", "Wallpaper")
    } catch {
        return ""
    }
    return FileExist(wp) ? wp : ""
}

; ---------------- 枚举桌面 ----------------
LoadItems() {
    global gItems
    gItems := []
    ; 系统项：默认在「系统」分区（可拖走，INI 会记住）
    gItems.Push({name: "回收站", path: "shell:::{645FF040-5081-101B-9F08-00AA002F954E}", clsid: "::{645FF040-5081-101B-9F08-00AA002F954E}", isDir: false, ext: "", special: "recycle", zone: ""})
    gItems.Push({name: "此电脑", path: "shell:::{20D04FE0-3AEA-1069-A2D8-08002B30309D}", clsid: "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}", isDir: false, ext: "", special: "computer", zone: ""})
    for it in gItems
        it.zone := GetSavedZone(it, "系统")
    Loop Files, A_Desktop . "\*", "FD" {
        if (A_LoopFileName = "desktop.ini")
            continue
        isDir := InStr(A_LoopFileAttrib, "D") > 0
        ext := ""
        if (!isDir)
            SplitPath(A_LoopFileFullPath, &fn, &fd, &ext, &noExt, &drv)
        ext := StrLower(ext)
        item := {name: A_LoopFileName, path: A_LoopFileFullPath, clsid: "", isDir: isDir, ext: ext, special: "", zone: ""}
        item.zone := GetSavedZone(item, Classify(item.name, ext, isDir))
        gItems.Push(item)
    }
}

DisplayName(item) {
    if (item.special != "")
        return item.name
    SplitPath(item.path, &fn, &fd, &ext, &noExt, &drv)
    dn := item.isDir ? fn : noExt
    if (StrLen(dn) > 12)
        dn := SubStr(dn, 1, 11) . "…"
    return dn
}

SizeIndex() {
    if (gIconSize = 32)
        return 1
    if (gIconSize = 64)
        return 3
    return 2
}

StatsText() {
    total := gItems.Length
    unorg := 0
    for item in gItems
        if (item.zone = "待整理")
            unorg++
    tidy := total > 0 ? Round((total - unorg) / total * 100) : 100
    return "图标总数：" . total . "`n待整理：" . unorg . "`n整洁度：" . tidy . "%"
}

; ---------------- GDI+ 面板背景 ----------------
; 做法：把壁纸拉伸到工作区尺寸，再把分区/小组件/底栏的圆角矩形区域
; 从壁纸上裁下来，叠一层半透明白 + 细边框，合成一张整屏背景图。
; 原始样式：面板里是原样壁纸（轻透，能看到壁纸）；毛玻璃：面板里是
; 模糊后的壁纸。两种都用这张图做背景，分区面板不再另画。
; 注意：AHK 原生控件做不到逐块亚克力，所以用“预渲染整屏背景”来模拟；
; 按钮仍是原生 Win32 外观。合成失败时返回 ""，BuildGui 回退到纯色面板。

global gGdipToken := 0
global gPanelRegen := false
global gPanelBg := false   ; 当前背景是否用了合成的面板背景图

GdipStartup() {
    global gGdipToken
    if (gGdipToken)
        return gGdipToken
    input := Buffer(24, 0)
    NumPut("UInt", 1, input, 0)  ; GdiplusVersion = 1
    status := DllCall("gdiplus\GdiplusStartup", "Ptr*", &gGdipToken, "Ptr", input, "Ptr", 0)
    if (status != 0 || !gGdipToken) {
        gGdipToken := 0
        return 0
    }
    return gGdipToken
}

; 注意：这里故意没有 GdipShutdown——进程退出时 DLL 已开始卸载，显式
; Shutdown 会访问已卸载的内存而崩溃（gdiplus.DLL_unloaded，0xc0000005）；
; GDI+ 由系统在进程结束时回收，不需要显式关闭。

; 取图片宽高
GdipImageSize(pImage, &w, &h) {
    DllCall("gdiplus\GdipGetImageWidth", "Ptr", pImage, "UInt*", &w)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", pImage, "UInt*", &h)
}

; 新建 ARGB 位图
GdipNewBitmap(w, h) {
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w, "Int", h, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap)
    return pBitmap
}

; 取位图的 Graphics（并设高质量双三次插值）
GdipGraphics(pBitmap) {
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pGraphics, "Int", 7)  ; 7 = HighQualityBicubic
    return pGraphics
}

; 把 pImage 按目标矩形画到 pGraphics 上
; GdipDrawImageRectRectI 完整签名共 14 个参数，末尾 3 个（imageAttributes / callback / callbackData）必须传 0，缺省会读到垃圾值
GdipDrawImage(pGraphics, pImage, dx, dy, dw, dh, sx, sy, sw, sh) {
    DllCall("gdiplus\GdipDrawImageRectRectI", "Ptr", pGraphics, "Ptr", pImage, "Int", dx, "Int", dy, "Int", dw, "Int", dh, "Int", sx, "Int", sy, "Int", sw, "Int", sh, "Int", 2, "Ptr", 0, "Ptr", 0, "Ptr", 0)  ; 2 = UnitPixel
}

; 模糊：先缩小到 1/factor 再放大回原尺寸（双三次插值产生柔和模糊）
GdipBlurBitmap(pSrc, w, h, factor := 10) {
    sw := Max(1, w // factor)
    sh := Max(1, h // factor)
    pSmall := GdipNewBitmap(sw, sh)
    gSmall := GdipGraphics(pSmall)
    GdipImageSize(pSrc, &iw, &ih)
    GdipDrawImage(gSmall, pSrc, 0, 0, sw, sh, 0, 0, iw, ih)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gSmall)
    pBlur := GdipNewBitmap(w, h)
    gBlur := GdipGraphics(pBlur)
    GdipDrawImage(gBlur, pSmall, 0, 0, w, h, 0, 0, sw, sh)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gBlur)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pSmall)
    return pBlur
}

; 圆角矩形路径
GdipRoundRectPath(x, y, w, h, r) {
    pPath := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)  ; 0 = FillModeAlternate
    d := r * 2
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", pPath)
    return pPath
}

; 纯色填充刷（ARGB）
GdipSolidBrush(argb) {
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &pBrush)
    return pBrush
}

; 画笔（ARGB，线宽）
GdipPen(argb, width) {
    pPen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", width, "Int", 2, "Ptr*", &pPen)  ; 2 = UnitPixel
    return pPen
}

; 保存位图为 PNG（用 CLSIDFromString 取 PNG 编码器）
GdipSavePng(pBitmap, outPath) {
    clsid := Buffer(16, 0)
    hr := DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    if (hr != 0)
        return false
    status := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "Str", outPath, "Ptr", clsid, "Ptr", 0)
    return status = 0
}

; 缓存键：工作区尺寸 + 样式（原始/毛玻璃）+ 壁纸文件大小/修改时间（壁纸换了就重新生成）
PanelCacheKey(wallpaper, w, h, blurred) {
    size := FileGetSize(wallpaper)
    mtime := ""
    try {
        FileGetTime(&mtime, wallpaper, "M")
    } catch {
        mtime := ""
    }
    return w . "x" . h . "_" . (blurred ? "frost" : "orig") . "_" . size . "_" . mtime
}

; 面板矩形（必须与 BuildGui 里的布局计算保持一致）
PanelRects(workW, workH) {
    margin := 16, gap := 12, topH := 64, bottomH := 56, rightW := 264
    zonesX := margin, zonesY := topH
    zonesW := workW - rightW - margin * 3
    zonesH := workH - topH - bottomH - margin
    rightX := workW - rightW - margin
    zoneW := (zonesW - gap * 2) // 3
    zoneH := (zonesH - gap) // 2
    rects := []
    for i in [1, 2, 3, 4, 5, 6] {
        zx := zonesX + Mod(i - 1, 3) * (zoneW + gap)
        zy := zonesY + ((i - 1) // 3) * (zoneH + gap)
        rects.Push({x: zx, y: zy, w: zoneW, h: zoneH, r: 16, divider: true})
    }
    rects.Push({x: rightX, y: zonesY, w: rightW, h: 150, r: 16, divider: false})
    wy2 := zonesY + 150 + gap
    rects.Push({x: rightX, y: wy2, w: rightW, h: 110, r: 16, divider: false})
    wy3 := wy2 + 110 + gap
    h3 := Min(zonesY + zonesH - wy3, 150)
    if (h3 > 60)
        rects.Push({x: rightX, y: wy3, w: rightW, h: h3, r: 16, divider: false})
    rects.Push({x: 0, y: workH - bottomH, w: workW, h: bottomH - 2, r: 12, divider: false})
    return rects
}

; 生成面板背景图，成功返回路径，失败返回 ""。
; blurred = false：原始样式（壁纸原样 + 轻透面板）；true：毛玻璃（壁纸模糊 + 面板）。
EnsurePanelBackground(workW, workH, blurred) {
    global gPanelRegen
    wp := GetWallpaper()
    if (wp = "")
        return ""
    if (!GdipStartup())
        return ""
    try {
        key := PanelCacheKey(wp, workW, workH, blurred)
        dir := A_Temp . "\DeskDrawer"
        DirCreate(dir)
        outPath := dir . "\bg_panel_" . key . ".png"
        if (!gPanelRegen && FileExist(outPath))
            return outPath
        gPanelRegen := false
        pWall := 0
        if (DllCall("gdiplus\GdipLoadImageFromFile", "Str", wp, "Ptr*", &pWall) != 0 || !pWall)
            return ""
        GdipImageSize(pWall, &iw, &ih)
        pBase := GdipNewBitmap(workW, workH)
        gBase := GdipGraphics(pBase)
        GdipDrawImage(gBase, pWall, 0, 0, workW, workH, 0, 0, iw, ih)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gBase)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pWall)
        pBlur := blurred ? GdipBlurBitmap(pBase, workW, workH, 10) : 0
        gScene := GdipGraphics(pBase)
        for rc in PanelRects(workW, workH) {
            pShadow := GdipRoundRectPath(rc.x, rc.y + 5, rc.w, rc.h, rc.r)
            pBrushS := GdipSolidBrush(0x1E000000)
            DllCall("gdiplus\GdipFillPath", "Ptr", gScene, "Ptr", pBrushS, "Ptr", pShadow)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrushS)
            DllCall("gdiplus\GdipDeletePath", "Ptr", pShadow)
            pPath := GdipRoundRectPath(rc.x, rc.y, rc.w, rc.h, rc.r)
            DllCall("gdiplus\GdipSetClipPath", "Ptr", gScene, "Ptr", pPath)
            if (blurred)
                GdipDrawImage(gScene, pBlur, 0, 0, workW, workH, 0, 0, workW, workH)
            pBrushW := GdipSolidBrush(blurred ? 0x64FFFFFF : 0x6EFFFFFF)
            DllCall("gdiplus\GdipFillPath", "Ptr", gScene, "Ptr", pBrushW, "Ptr", pPath)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrushW)
            DllCall("gdiplus\GdipResetClip", "Ptr", gScene)
            pPen := GdipPen(0xB4FFFFFF, 1.5)
            DllCall("gdiplus\GdipDrawPath", "Ptr", gScene, "Ptr", pPen, "Ptr", pPath)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pPen)
            if (rc.divider) {
                pBrushL := GdipSolidBrush(0x80D8D8D8)
                DllCall("gdiplus\GdipFillRectangleI", "Ptr", gScene, "Ptr", pBrushL, "Int", rc.x + 14, "Int", rc.y + 32, "Int", rc.w - 28, "Int", 1)
                DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrushL)
            }
            DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
        }
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gScene)
        if (blurred)
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBlur)
        ok := GdipSavePng(pBase, outPath)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBase)
        return ok ? outPath : ""
    } catch {
        return ""
    }
}

; ---------------- 建窗 ----------------
BuildGui() {
    global gGui, gGlass, gIconSize, gPage, gTotalPages, gPerZone, gZoneNames, gItems, gSearch, gIconHwnds, gZoneRects, gIcons, gClockCtrl, gDateCtrl, gPageText, gStatusCtrl, gPanelBg
    LoadItems()
    MonitorGetWorkArea(1, &waL, &waT, &waR, &waB)
    workW := waR - waL, workH := waB - waT

    gGui := Gui("+AlwaysOnTop -Caption +ToolWindow", "DeskDrawer")
    gGui.OnEvent("Escape", (*) => HideDrawer())
    gGui.OnEvent("Close", OnGuiClose)

    ; 背景：默认（毛玻璃关）用 GDI+ 合成的原始样式背景（壁纸 + 轻透面板）；
    ; 毛玻璃开时用模糊版；合成失败时回退到原壁纸 + 纯色面板（旧样子）。
    gPanelBg := false
    bgPath := EnsurePanelBackground(workW, workH, gGlass)
    gPanelBg := bgPath != ""
    if (gPanelBg) {
        gGui.Add("Picture", "x0 y0 w" . workW . " h" . workH, bgPath)
    } else if (!gGlass) {
        wp := GetWallpaper()
        if (wp != "")
            gGui.Add("Picture", "x0 y0 w" . workW . " h" . workH, wp)
        else
            gGui.BackColor := "2B2B2B"
    } else {
        gGui.BackColor := "000000"
    }

    subColor   := "666666"   ; 底栏文字（底栏面板两种模式下都是浅色）
    panelColor := gGlass ? "FFFFFF" : "F2F2F2"   ; 分区底色（纯色；真半透明 AHK 控件做不到）

    ; 顶栏：白字 + 1px 黑阴影浮在壁纸上（BackgroundTrans 去掉默认白底）
    gGui.SetFont("s16 bold c000000", "Segoe UI")
    gGui.Add("Text", "x17 y13 w400 h28 BackgroundTrans", "DeskDrawer")
    gGui.SetFont("s16 bold cFFFFFF", "Segoe UI")
    gGui.Add("Text", "x16 y12 w400 h28 BackgroundTrans", "DeskDrawer")
    gGui.SetFont("s10 cFFFFFF", "Segoe UI")
    gGui.Add("Text", "x16 y40 w400 h18 BackgroundTrans", "桌面抽屉 · 融入桌面的整理工具")
    gGui.Add("Text", "x" . (workW - 320) . " y20 w304 h20 Right BackgroundTrans", "Win+Alt+D 呼出 · Esc 隐藏")

    ; 布局尺寸
    margin := 16, gap := 12, topH := 64, bottomH := 56, rightW := 264
    zonesX := margin, zonesY := topH
    zonesW := workW - rightW - margin * 3
    zonesH := workH - topH - bottomH - margin
    rightX := workW - rightW - margin
    zoneW := (zonesW - gap * 2) // 3
    zoneH := (zonesH - gap) // 2
    cellW := gIconSize + 28, cellH := gIconSize + 36
    iconCols := Max(1, (zoneW - 24) // cellW)
    iconRows := Max(1, (zoneH - 52) // cellH)
    gPerZone := iconCols * iconRows

    ; 总页数：按单分区容量算
    pages := 1
    for zoneName in gZoneNames {
        n := 0
        for item in gItems
            if (item.zone = zoneName)
                n++
        pages := Max(pages, Ceil(n / gPerZone))
    }
    gTotalPages := Max(1, pages)
    if (gPage > gTotalPages)
        gPage := gTotalPages

    ; 分区（3 列 x 2 行）
    for zi, zoneName in gZoneNames {
        zx := zonesX + Mod(zi - 1, 3) * (zoneW + gap)
        zy := zonesY + ((zi - 1) // 3) * (zoneH + gap)
        gZoneRects.Push({name: zoneName, x: zx, y: zy, w: zoneW, h: zoneH})
        count := 0
        for item in gItems
            if (item.zone = zoneName)
                count++
        if (!gPanelBg) {
            gGui.Add("Text", "x" . zx . " y" . zy . " w" . zoneW . " h" . zoneH . " Background" . panelColor, "")
            gGui.Add("Text", "x" . (zx + 14) . " y" . (zy + 32) . " w" . (zoneW - 28) . " h1 BackgroundD8D8D8", "")
        }
        gGui.SetFont("s11 bold c0078D4", "Segoe UI")
        gGui.Add("Text", "x" . (zx + 14) . " y" . (zy + 10) . " w" . (zoneW - 28) . " h20 BackgroundTrans", zoneName . " · " . count)
        ; 该分区当前页的图标
        startIdx := (gPage - 1) * gPerZone
        k := 0
        for item in gItems {
            if (item.zone != zoneName)
                continue
            k++
            if (k <= startIdx || k > startIdx + gPerZone)
                continue
            pos := k - startIdx - 1
            ix := zx + 14 + Mod(pos, iconCols) * cellW
            iy := zy + 36 + (pos // iconCols) * cellH
            hIcon := GetIcon(item)
            gIcons.Push(hIcon)
            pic := gGui.Add("Picture", "x" . ix . " y" . iy . " w" . gIconSize . " h" . gIconSize, "HICON:" . hIcon)
            gGui.SetFont("s9 c333333", "Segoe UI")
            lbl := gGui.Add("Text", "x" . (ix - 14) . " y" . (iy + gIconSize + 2) . " w" . cellW . " h16 Center BackgroundTrans", DisplayName(item))
            rec := {item: item, pic: pic, lbl: lbl}
            gIconHwnds[pic.Hwnd] := rec
            gIconHwnds[lbl.Hwnd] := rec
            pic.OnEvent("Click", SelectItem.Bind(item))
            pic.OnEvent("DoubleClick", OpenItem.Bind(item))
            lbl.OnEvent("DoubleClick", OpenItem.Bind(item))
        }
    }

    ; 右列小组件
    wx := rightX, wy := zonesY, ww := rightW
    if (!gPanelBg)
        gGui.Add("Text", "x" . wx . " y" . wy . " w" . ww . " h150 Background" . panelColor, "")
    gGui.SetFont("s11 bold c333333", "Segoe UI")
    gGui.Add("Text", "x" . (wx + 14) . " y" . (wy + 10) . " w" . (ww - 28) . " h20 BackgroundTrans", "时钟")
    gGui.SetFont("s26 bold c1A1A1A", "Segoe UI")
    gClockCtrl := gGui.Add("Text", "x" . (wx + 14) . " y" . (wy + 36) . " w" . (ww - 28) . " h44 BackgroundTrans", "--:--:--")
    gGui.SetFont("s11 c666666", "Segoe UI")
    gDateCtrl := gGui.Add("Text", "x" . (wx + 14) . " y" . (wy + 88) . " w" . (ww - 28) . " h20 BackgroundTrans", "")
    gGui.Add("Text", "x" . (wx + 14) . " y" . (wy + 114) . " w" . (ww - 28) . " h20 BackgroundTrans", "天气未接入")

    wy2 := wy + 150 + gap
    if (!gPanelBg)
        gGui.Add("Text", "x" . wx . " y" . wy2 . " w" . ww . " h110 Background" . panelColor, "")
    gGui.SetFont("s11 bold c333333", "Segoe UI")
    gGui.Add("Text", "x" . (wx + 14) . " y" . (wy2 + 10) . " w" . (ww - 28) . " h20 BackgroundTrans", "桌面概览")
    gGui.SetFont("s11 c333333", "Segoe UI")
    gGui.Add("Text", "x" . (wx + 14) . " y" . (wy2 + 36) . " w" . (ww - 28) . " h64 BackgroundTrans", StatsText())

    wy3 := wy2 + 110 + gap
    h3 := Min(zonesY + zonesH - wy3, 150)   ; 操作提示面板不拉太长，下面留出壁纸
    if (h3 > 60) {
        if (!gPanelBg)
            gGui.Add("Text", "x" . wx . " y" . wy3 . " w" . ww . " h" . h3 . " Background" . panelColor, "")
        gGui.SetFont("s11 bold c333333", "Segoe UI")
        gGui.Add("Text", "x" . (wx + 14) . " y" . (wy3 + 10) . " w" . (ww - 28) . " h20 BackgroundTrans", "操作提示")
        gGui.SetFont("s10 c666666", "Segoe UI")
        gGui.Add("Text", "x" . (wx + 14) . " y" . (wy3 + 36) . " w" . (ww - 28) . " h" . (h3 - 46) . " BackgroundTrans", "双击图标打开`n拖动图标换分区`n点「一键整理」自动归位`nEsc 隐藏 · Win+Alt+D 呼出")
    }

    ; 底栏（整条浅色面板打底，控件不再直接浮在壁纸上）
    by := workH - bottomH + 6
    if (!gPanelBg)
        gGui.Add("Text", "x0 y" . (by - 6) . " w" . workW . " h" . (bottomH - 2) . " Background" . panelColor, "")
    bx := 16
    gGui.SetFont("s10 c" . subColor, "Segoe UI")
    gGui.Add("Text", "x" . bx . " y" . (by + 6) . " w36 h20 BackgroundTrans", "搜索")
    bx += 40
    searchEdit := gGui.Add("Edit", "x" . bx . " y" . by . " w200 h26", gSearch)
    searchEdit.OnEvent("Change", OnSearchChange)
    bx += 212
    orgBtn := gGui.Add("Button", "x" . bx . " y" . by . " w96 h28", "一键整理")
    orgBtn.OnEvent("Click", (*) => OrganizeAll())
    bx += 104
    refBtn := gGui.Add("Button", "x" . bx . " y" . by . " w64 h28", "刷新")
    refBtn.OnEvent("Click", (*) => RefreshAll())
    bx += 72
    glassChk := gGui.Add("CheckBox", "x" . bx . " y" . (by + 4) . " w84 h20 BackgroundTrans" . (gGlass ? " Checked" : ""), "毛玻璃")
    glassChk.OnEvent("Click", OnGlassToggle)
    bx += 96
    sizeDdl := gGui.Add("DropDownList", "x" . bx . " y" . by . " w96 h28 Choose" . SizeIndex(), ["小 32", "中 48", "大 64"])
    sizeDdl.OnEvent("Change", OnSizeChange)
    bx += 112
    prevBtn := gGui.Add("Button", "x" . bx . " y" . by . " w36 h28", "◀")
    prevBtn.OnEvent("Click", (*) => ChangePage(-1))
    bx += 40
    gPageText := gGui.Add("Text", "x" . bx . " y" . (by + 5) . " w72 h20 Center BackgroundTrans", "第 " . gPage . "/" . gTotalPages . " 页")
    bx += 76
    nextBtn := gGui.Add("Button", "x" . bx . " y" . by . " w36 h28", "▶")
    nextBtn.OnEvent("Click", (*) => ChangePage(1))
    bx += 48
    ; 状态文本：只在有剩余空间时显示
    statusW := workW - 96 - 8 - bx
    if (statusW > 80)
        gStatusCtrl := gGui.Add("Text", "x" . bx . " y" . (by + 5) . " w" . statusW . " h20 Right BackgroundTrans", "就绪")
    else
        gStatusCtrl := ""
    hideBtn := gGui.Add("Button", "x" . (workW - 96) . " y" . by . " w80 h28", "隐藏")
    hideBtn.OnEvent("Click", (*) => HideDrawer())

    gGui.Show("x" . waL . " y" . waT . " w" . workW . " h" . workH)
    if (gGlass && !gPanelBg)
        EnableBlur(gGui.Hwnd, true)
    UpdateClock()
}

; 刷新：重建窗口，并强制重新生成面板背景（换了壁纸后用）
RefreshAll() {
    global gPanelRegen
    gPanelRegen := true
    RebuildGui()
}

; ---------------- 重建 ----------------
RebuildGui() {
    global gClockCtrl, gDateCtrl, gGui, gIcons, gIconHwnds, gZoneRects
    gClockCtrl := "", gDateCtrl := ""
    if (gGui != "") {
        for hIcon in gIcons
            DllCall("user32\DestroyIcon", "Ptr", hIcon)
        gIcons := []
        gGui.Destroy()
        gGui := ""
    }
    gIconHwnds := Map()
    gZoneRects := []
    BuildGui()
}

OnGuiClose(*) {
    HideDrawer()
    return true  ; 阻止关闭（Alt+F4 也只是隐藏）；退出请用托盘菜单
}

; ---------------- 事件 ----------------
OpenItem(item, ctrl := "", info := "") {
    if (item.special != "") {
        Run("explorer " . item.path)
    } else {
        try {
            Run('"' . item.path . '"')
        } catch {
            ToolTip("无法打开：" . item.name)
            SetTimer(() => ToolTip(), -2000)
        }
    }
}

SelectItem(item, ctrl := "", info := "") {
    if (A_TickCount - gSuppressClick < 500)
        return
    if (gStatusCtrl != "")
        gStatusCtrl.Text := "已选：" . item.name . "（双击打开，拖到其他分区可移动）"
}

OnSearchChange(ctrl, info) {
    global gSearch
    gSearch := ctrl.Value
    ApplySearchFilter()
}

; 搜索只做显隐过滤（不重建窗口，避免输入中途丢失焦点）；仅筛选当前页
ApplySearchFilter() {
    needle := StrLower(Trim(gSearch))
    for hwnd, rec in gIconHwnds {
        show := (needle = "") || InStr(StrLower(rec.item.name), needle)
        rec.pic.Visible := show
        rec.lbl.Visible := show
    }
}

OrganizeAll() {
    moved := 0
    for item in gItems {
        if (item.special != "")
            continue
        if (item.zone = "待整理") {
            target := Classify(item.name, item.ext, item.isDir)
            if (target != "待整理") {
                SetItemZone(item, target)
                moved++
            }
        }
    }
    RebuildGui()
    ToolTip("已整理 " . moved . " 个图标到对应分区")
    SetTimer(() => ToolTip(), -2000)
}

ChangePage(delta) {
    global gPage, gTotalPages
    np := gPage + delta
    if (np < 1 || np > gTotalPages)
        return
    gPage := np
    RebuildGui()
}

OnSizeChange(ctrl, info) {
    global gIconSize, gIconSizes
    gIconSize := gIconSizes[ctrl.Value]
    SaveSettings()
    RebuildGui()
}

OnGlassToggle(ctrl, info) {
    global gGlass
    gGlass := ctrl.Value = 1
    SaveSettings()
    RebuildGui()
}

HideDrawer() {
    if (gGui != "")
        gGui.Hide()
}

ShowDrawer() {
    if (gGui = "")
        BuildGui()
    else
        gGui.Show()
}

ToggleDrawer() {
    if (gGui = "") {
        BuildGui()
        return
    }
    if (!DllCall("user32\IsWindowVisible", "Ptr", gGui.Hwnd))
        ShowDrawer()
    else if (WinActive("ahk_id " . gGui.Hwnd))
        HideDrawer()
    else
        gGui.Show()
}

UpdateClock() {
    try {
        if (gGui = "" || gClockCtrl = "")
            return
        gClockCtrl.Text := FormatTime(, "HH:mm:ss")
        gDateCtrl.Text := FormatTime(, "yyyy年M月d日 dddd")
    } catch {
        ; 控件已销毁时忽略
    }
}

; ---------------- 拖拽换分区 ----------------
; Picture 控件没有鼠标按下事件，用 WM_LBUTTONDOWN 在窗口级捕获，
; 再查鼠标下的控件句柄是不是图标/标签。
OnMessage(0x0201, WM_LBUTTONDOWN)

WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global gGui, gIconHwnds, gDrag, gDragging
    if (gGui = "" || gDragging)
        return
    MouseGetPos(&mx, &my, &win, &ctrlHwnd, 2)
    if (win != gGui.Hwnd || ctrlHwnd = 0 || !gIconHwnds.Has(ctrlHwnd))
        return
    rec := gIconHwnds[ctrlHwnd]
    rec.pic.GetPos(&px, &py)
    rec.lbl.GetPos(&lx, &ly)
    gDrag := {rec: rec, startX: mx, startY: my, picX: px, picY: py, lblX: lx, lblY: ly, moved: false}
    gDragging := true
    SetTimer(DragTick, 10)
}

DragTick() {
    global gDrag, gDragging, gSuppressClick
    if (!gDragging)
        return
    if (!GetKeyState("LButton", "P")) {
        SetTimer(DragTick, 0)
        if (gDrag.moved) {
            gSuppressClick := A_TickCount
            DropIcon()
        }
        gDragging := false
        gDrag := ""
        return
    }
    MouseGetPos(&mx, &my)
    dx := mx - gDrag.startX, dy := my - gDrag.startY
    if (!gDrag.moved && (Abs(dx) > 5 || Abs(dy) > 5))
        gDrag.moved := true
    if (gDrag.moved) {
        gDrag.rec.pic.Move(gDrag.picX + dx, gDrag.picY + dy)
        gDrag.rec.lbl.Move(gDrag.lblX + dx, gDrag.lblY + dy)
    }
}

DropIcon() {
    MouseGetPos(&mx, &my)
    gGui.GetPos(&gx, &gy)
    cx := mx - gx, cy := my - gy
    for zr in gZoneRects {
        if (cx >= zr.x && cx < zr.x + zr.w && cy >= zr.y && cy < zr.y + zr.h) {
            if (gDrag.rec.item.zone != zr.name)
                SetItemZone(gDrag.rec.item, zr.name)
            break
        }
    }
    RebuildGui()
}

; ---------------- 托盘与热键 ----------------
A_TrayMenu.Add("显示 / 隐藏抽屉", (*) => ToggleDrawer())
A_TrayMenu.Add()
A_TrayMenu.Add("退出", (*) => ExitApp())
A_IconTip := "DeskDrawer — 桌面抽屉"

#!d::ToggleDrawer()

; ---------------- 启动 ----------------
GdipStartup()  ; 面板背景用；失败时自动回退到纯色面板，不影响运行
; 注意：不要调 GdipShutdown（也不要注册 OnExit 去调它）——进程退出时
; Windows 已开始卸载 DLL，此时 Shutdown 会访问已卸载的内存而崩溃
; （gdiplus.DLL_unloaded，0xc0000005）；GDI+ 由系统在进程结束时回收。
LoadSettings()
BuildGui()
SetTimer(UpdateClock, 1000)
