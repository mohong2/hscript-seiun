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
- **或模式（or-pattern）**：`case 1 | 2:`、`case "a" | "b" if (cond):`（与 Haxe 4.2+ 一致）；
  需要按位或时加括号：`case (1 | 2):`
- **带守卫的通配 case**：`case _ if (cond):`
- **解构扩展**：rest（`var [a, ...rest] = arr;`）、重命名（`var {x: y} = obj;`）、
  默认值（`var {x = 1} = obj;`）、嵌套（`var {a: [b, c]} = obj;`）、
  `for ([a, b] in pairs)`、赋值形式（`[a, b] = f();`、`{x} = obj;`）
- **泛型函数**：`function f<T>(x:T):T`（类型参数在解析期擦除）
- **Map 推导式**：`[for (k => v in map) k => v]`
- **通配导入**：`import haxe.ds.*;`
- 无类型 `catch (e)` 与空语句 `;`

测试过程中还修了：局部变量 `++`/`--` 不写回、可选参数默认值、`?.` 空安全调用、
无 `-D hscriptPos` 时错误被吞的问题。

**1.3.0 行为变更：** `case 1 | 2:` 以前会被解析成按位或表达式 `(1 | 2)`，
因此永远匹配不上；现在它是或模式（与 Haxe 一致）。确实需要按位或时请写 `case (1 | 2):`。

## 性能

1.3.0 对解析器与解释器做了一轮基于 profiling 的重写。数据由仓库自带 `bench/` 测试台
在 eval 目标、`-D hscriptPos`（引擎的实际配置）下测得；方法论、语料与验收阈值见
[bench/README.md](bench/README.md)。

| | 优化前 | 优化后 | 变化 |
| --- | --- | --- | --- |
| 解析（合计） | 26.38 ms | 22.12 ms | **-16%** |
| 执行（合计） | 63.00 ms | 39.36 ms | **-38%** |

两列都是同一台机器上 7 组交替测量（`git archive HEAD` 的干净副本 vs 1.3.0 工作树）的中位数，
属于同条件对比；若各自只取最好的一次，则是解析 -11%、执行 -38%。

主要手段：字符串字面量走子串快速路径、词法器不再分配闭包、`-D hscriptPos` 下用数组
栈代替每个 token 一个 `TokenPos` 对象、单字符 token 驻留复用、运算符表全局共享
（不再为每个 `Interp` 分配约 40 个闭包）、脚本类实例化只建一个实例
（不再每层继承各建一个影子父实例 + 解释器）。

自行复现：

```powershell
$env:BENCH_LABEL='mine'
haxe -cp . -cp bench -D hscriptPos -D CUSTOM_CLASSES `
  --macro "hscript.macros.UsingHandler.init()" `
  --macro "hscript.macros.ClassExtendMacro.init()" -main Bench --interp
$env:BENCH_COMPARE='baseline,mine'
haxe -cp . -cp bench -D hscriptPos -D CUSTOM_CLASSES `
  --macro "hscript.macros.UsingHandler.init()" `
  --macro "hscript.macros.ClassExtendMacro.init()" -main Bench --interp
```

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

- `using StringTools;`（以及 `using` 脚本类）在 1.3.0 的 eval 目标上实测可用；
  上游关于静态方法反射的说明只对 neko 目标成立。
- 尚未实现（见 [docs/FEATURES.md](docs/FEATURES.md)）：对象展开（`{...a, b: 1}`）、
  switch 的数组/对象模式（`case [a, b]:`、`case {x: v}:`）、`enum abstract`、
  以及 `implements I, J` 这种逗号分隔的接口列表。
- `hscript.Checker` 静态分析未接入运行时，也没有测试覆盖。
- `hscript.Bytes`（脚本缓存）现已能完整往返所有语法，格式也加了版本号；
  但引擎目前还没有任何路径去加载缓存脚本，所以运行时还享受不到缓存带来的解析开销节省。
  解码耗时约为解析阶段的三分之一，详见 [docs/COMPAT.md](docs/COMPAT.md)。
- `import some.pkg.*;` 是惰性解析的：Haxe 运行时无法枚举包，因此包前缀写错时 `import`
  本身不会报错，而是在首次使用其中某个标识符时报 `Unknown variable`。
- 或模式里的标识符分支是"通配绑定"，从左到右优先匹配，所以 `case v | 5:` 总会通过 `v` 命中；
  守卫只能看到真正命中的那个分支绑定的变量，因此 `case 5 | x if (x == 5):` 会报
  `Unknown variable: x`。
- 覆盖 `@:deprecated` 基类成员的脚本类会回退到 Haxe 实现：
  影子类宏不再为已废弃成员生成转发 override（这正是引擎 `WDeprecated` 警告消失的原因）。
- 裸枚举构造 `B(3)` 依旧不支持，请写 `E.B(3)`。

## License

MIT。本库是 hscript / hscript-iris / hscript-improved / hscript-plus
四个 MIT 项目的派生合并，版权与来源说明见 [NOTICE](NOTICE) 与 [LICENSE](LICENSE)。
