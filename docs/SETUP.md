# Installation & Setup

## Install the library

From git (recommended):

```bat
haxelib git hscript-seiun https://github.com/mohong2/hscript-seiun.git
```

For local development against a checked-out copy:

```bat
haxelib dev hscript-seiun <path-to-repo>
```

## Project setup

### Haxe projects (build.hxml)

```hxml
--library hscript-seiun
# optional: descriptive traces and better runtime error handling
-D hscriptPos
# optional: enable script classes extending engine classes (_HSX / _HSC)
-D CUSTOM_CLASSES
```

### OpenFL / Flixel projects (Project.xml)

```xml
<haxelib name="hscript-seiun"/>
<haxedef name="hscriptPos"/>      <!-- optional -->
<define name="CUSTOM_CLASSES"/>   <!-- optional -->
```

`extraParams.hxml` in the repo root automatically injects the two compile-time
macros (`UsingHandler.init()` / `ClassExtendMacro.init()`), so nothing else is
required.

## Running the test-suite

```bat
haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES ^
  --macro hscript.macros.UsingHandler.init() ^
  --macro hscript.macros.ClassExtendMacro.init() ^
  -main TestMain --interp
```

---

## 中文安装说明

从 git 安装（推荐）：

```bat
haxelib git hscript-seiun https://github.com/mohong2/hscript-seiun.git
```

本地开发：

```bat
haxelib dev hscript-seiun <仓库路径>
```

Haxe 项目（build.hxml）：

```hxml
--library hscript-seiun
-D hscriptPos        # 可选：更详细的运行时错误
-D CUSTOM_CLASSES    # 可选：脚本类 extends 引擎类
```

OpenFL / Flixel 项目（Project.xml）：

```xml
<haxelib name="hscript-seiun"/>
<haxedef name="hscriptPos"/>      <!-- 可选 -->
<define name="CUSTOM_CLASSES"/>   <!-- 可选 -->
```

仓库根目录的 `extraParams.hxml` 会自动注入两个编译期宏，无需手动配置。
