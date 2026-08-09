# hscript-seiun（中文版）

[English](README.md) | [中文](README_zh-CN.md)

**超级结合体版 HaxeScript** —— 以 [hscript-iris](https://github.com/crowplexus/hscript-iris) 1.1.3 为底座，
缝合 [hscript-improved](https://github.com/FNF-CNE-Devs/hscript-improved) 与
[hscript-plus](https://github.com/DleanJeans/hscript-plus)，为 SeiunEngine 定制的脚本运行时。
三者均为 MIT 许可，来源与版权说明见 [NOTICE](NOTICE)。

包名从 `hscript` 开始：合并运行时的主包是 `hscript.*`（`hscript.Parser`、`hscript.Interp` ...），
iris 工具放在 `hscript.iris.*`；上游 iris 的 `crowplexus` 前缀已去掉。

## 特性

### 来自 hscript-iris（保留）

- `import` + 别名（`import Foo as Bar`）、`package`、`using`
- `final` 常量、`enum`、`typedef` 重定向
- 空值合并 `??` / `??=`
- 改进的错误处理、`showPosOnLog`
- for 循环迭代器缓存等性能优化

### 来自 hscript-improved（FNF-CNE-Devs）

- **脚本类**：`class Foo { ... }`、`new Foo()`、字段/方法/`this`
- **CUSTOM_CLASSES 宏**：脚本类可 `extends` 引擎类（如 `class MySprite extends FlxSprite`），
  编译期生成 `_HSX` 影子类，运行时可覆盖引擎方法
- `scriptObject`（父对象绑定，`this` 解析）
- `static` / `public` 变量与函数（`staticVariables` / `publicVariables`，`allowStaticVariables` / `allowPublicVariables`）
- `errorHandler`、`importFailedCallback`、`importBlocklist`、`importRedirects`
- `getRedirects` / `setRedirects`、`@:bypassAccessor`
- `Abstract` / `Enum` 的 `_HSC` 影子类（UsingHandler 宏）

### 来自 hscript-plus

- **脚本类继承**：`class Dog extends Animal {}`（两个都是脚本类），
  实例为带 `__sname__` + `super` 链的 Dynamic 对象，方法覆盖 / 继承字段 / `super.method()` 均可用
- 访问修饰符：`public` / `private` / `static` / `override` / `dynamic` / `inline`

### 其他合并增强

- 键值对 for：`for (k => v in map)`
- 脚本类静态变量**跨实例真正共享**（共享 `staticVariables` 引用）
- 类字段赋值同时同步 locals 与变量表，`obj.field` 始终读到最新值

### Haxe 语法补充

- **字符串插值**：`"v=$x"`、`"v=${x + 2}"`、`"${obj.field}"`；`$$` 是转义美元符，与 Haxe 一致
- **`cast`**：`cast (x, T)`（目标可解析为真实类时做类型校验，不匹配抛 "Cast error"）
  与 `cast x`（不校验）
- **`untyped`**：解析并直接执行包裹的表达式
- **泛型构造参数**：`new Array<Int>()`、`new Array<Array<Int>>()`（类型参数按编译期概念丢弃）
- **对象简写**（Haxe 4）：`{x}` 等价于 `{x: x}`
- **解构声明**（Haxe 4）：`var [a, b] = arr;` 与 `var {x, y} = obj;`
- **展开调用与 rest 参数**：`f(...arr)` 和 `function f(a, ...rest)`
- **类名直接访问静态成员**：`M.staticMethod()`、`S.staticVar`、`S.staticVar = 9`，
  静态字段在类声明时只求值一次
- **switch 守卫**：`case v if (v > 3):` 会把 `v` 绑定为被 switch 的值

测试过程中还修了：局部变量 `++`/`--` 不写回、可选参数默认值、`?.` 空安全调用、
无 `-D hscriptPos` 时错误被吞的问题。

## 运行时预处理（`#if`）

脚本内置 Haxe 风格的**条件执行**（注意：是脚本运行时解析，不是编译期条件编译）：

```haxe
#if android
var plat = "android";
#elseif ios
var plat = "ios";
#else
var plat = "other";
#end
```

支持 `#if` / `#elseif` / `#else` / `#end`、`!`、`&&`、`||` 与括号。
判断依据是 `Parser.preprocessorValues` 中**是否存在**该键（值是什么无所谓，与 Haxe
`#if` 语义一致）；嵌套 `#if` 与多层 `#elseif` 链均可正确配对。

引擎接入方（如 SeiunEngine 的 `HScript`）默认会注入平台键：
`android` / `ios` / `windows` / `linux` / `mac` / `web` / `html5` /
`desktop` / `mobile` / `sys`，以及 `engine` / `engineName` / `hscript`。
自定义键直接 `parser.preprocessorValues.set("myFeature", true)` 即可。

历史遗留的拼写别名 `preprocesorValues`（少一个 s）仍可用，写入会自动同步到
`preprocessorValues`。

## 安装

```bat
haxelib git hscript-seiun https://github.com/mohong2/hscript-seiun.git
```

本地开发：

```bat
haxelib dev hscript-seiun <本仓库路径>
```

然后在 `project.xml` 中：

```xml
<haxelib name="hscript-seiun"/>
<!-- 可选：开启脚本类 extends 引擎类 -->
<define name="CUSTOM_CLASSES"/>
```

库根目录的 `extraParams.hxml` 会自动注入两个编译期宏
（`UsingHandler.init()` / `ClassExtendMacro.init()`），无需手动添加。
Haxe / OpenFL / Flixel 项目示例见 [docs/SETUP.md](docs/SETUP.md)。

## 测试

```bat
haxe -cp . -cp test -D hscriptPos -D CUSTOM_CLASSES ^
  --macro hscript.macros.UsingHandler.init() ^
  --macro hscript.macros.ClassExtendMacro.init() ^
  -main TestMain --interp
```

覆盖：iris 语法、脚本类、脚本类继承、静态共享、错误处理器、导入回调、blocklist、
scriptObject、redirect、using、宏扩展类（extends 引擎类）、Bytes 往返、Printer、
键值对 for、运行时预处理（`#if` 条件编译）。

## 配置（宏作用域）

`hscript.Config` 控制两个宏扫描的包前缀（默认对齐 SeiunEngine 自身包结构）：

- `ALLOWED_CUSTOM_CLASSES`：哪些包下的类生成 `_HSX` 影子（默认 `flixel/openfl/script/states/substates/backend/options/editors/mohong`）
- `ALLOWED_ABSTRACT_AND_ENUM`：哪些包下的 abstract/enum 生成 `_HSC` 影子
- `DISALLOW_CUSTOM_CLASSES` / `DISALLOW_ABSTRACT_AND_ENUM`：按模块名拉黑

注意：**不要**把 `haxe`、`lime` 整个包放进去（会对 std 类做宏，
容易炸 `haxe.Int64` 这类 abstract）；确需某几个类时逐类添加。

## 已知限制（继承自上游）

- `Async.hx` / `Checker.hx` 在 hscript-iris 1.1.3 上游就存在编译问题
  （`hscriptPos` 下类型不匹配），引擎运行路径不引用它们；本库仅做了少量顺手修复（EField 参数）。
- `using StringTools` 依赖静态方法反射，`neko --interp` 下不可用（上游行为），cpp 真机目标可用。
- 脚本类构造器链：`class Child extends Parent` 时，父类字段会在子实例中重求值，
  父构造器只会在子实例上执行一次；显式 `super.new()` 目前不保证绑定到子实例
  （与 hscript-improved 上游行为一致）。

## License

MIT。本库是 hscript / hscript-iris / hscript-improved / hscript-plus
四个 MIT 项目的派生合并，版权与来源说明见 [NOTICE](NOTICE) 与 [LICENSE](LICENSE)。
