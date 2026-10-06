/*
 * hscript-seiun benchmark harness (MIT).
 *
 * Run from the repository root, e.g.:
 *
 *   set BENCH_LABEL=before
 *   haxe -cp . -cp bench -D hscriptPos -D CUSTOM_CLASSES ^
 *        --macro "hscript.macros.UsingHandler.init()" ^
 *        --macro "hscript.macros.ClassExtendMacro.init()" ^
 *        -main Bench --interp
 *
 *   set BENCH_COMPARE=before,after
 *   haxe -cp . -cp bench ... -main Bench --interp
 *
 * Configuration is read from environment variables so the harness behaves
 * identically under --interp (no argv forwarding available) and under -cpp:
 *
 *   BENCH_LABEL=name        result label -> bench/results/<name>.json
 *   BENCH_COMPARE=a,b       diff two result files instead of measuring
 *   BENCH_FILES=a.hx;b.hx   extra corpus files
 *   BENCH_ITERS / BENCH_EXEC_ITERS   initial iteration counts (auto-calibrated)
 *
 * Methodology: every measurement auto-calibrates its iteration count so one
 * round takes about ROUND_TARGET_MS, then takes the fastest of ROUNDS rounds.
 * Best-of-rounds is the standard microbenchmark estimator and removes the GC
 * and scheduler noise that makes single samples swing by 2x on the eval target.
 */
package;

import hscript.Interp;
import hscript.Parser;
import sys.io.File;

class Bench {
	static inline var ROUND_TARGET_MS = 120.0;
	static inline var ROUNDS = 9;
	static inline var MIN_ITERS = 20;
	static inline var MAX_ITERS = 20000;

	static var parseIters = 200;
	static var execIters = 100;

	static function main() {
		var envIters = Sys.getEnv("BENCH_ITERS");
		if (envIters != null && envIters != "") parseIters = Std.parseInt(envIters);
		var envExec = Sys.getEnv("BENCH_EXEC_ITERS");
		if (envExec != null && envExec != "") execIters = Std.parseInt(envExec);

		var envCompare = Sys.getEnv("BENCH_COMPARE");
		if (envCompare != null && envCompare != "" && envCompare.indexOf(",") > 0) {
			var parts = envCompare.split(",");
			compare(StringTools.trim(parts[0]), StringTools.trim(parts[1]));
			return;
		}

		var envLabel = Sys.getEnv("BENCH_LABEL");
		var label = (envLabel == null || envLabel == "") ? "current" : envLabel;

		var scripts = Corpus.all();
		var envFiles = Sys.getEnv("BENCH_FILES");
		if (envFiles != null && envFiles != "")
			for (f in envFiles.split(";"))
				if (StringTools.trim(f) != "")
					scripts.push({name: StringTools.trim(f), src: File.getContent(StringTools.trim(f))});

		Sys.println('hscript-seiun bench | label=' + label
			+ ' | hscriptPos=' + #if hscriptPos "on" #else "off" #end
			+ ' | custom_classes=' + #if CUSTOM_CLASSES "on" #else "off" #end
			+ ' | target=' + targetName());

		var results:Array<{name:String, chars:Int, parseMs:Float, execMs:Float}> = [];
		var errors:Array<String> = [];
		var totalChars = 0;
		var totalParse = 0.0;
		var totalExec = 0.0;

		for (s in scripts) {
			if (s.src.length == 0) continue;
			var r = {parseMs: 0.0, execMs: 0.0};
			try {
				r = measure(s.name, s.src);
			} catch (e:Dynamic) {
				var msg = Std.string(e);
				Sys.println(pad(s.name, 12) + ' ERRORED: ' + msg);
				errors.push(s.name + ": " + msg);
				continue;
			}
			results.push({name: s.name, chars: s.src.length, parseMs: r.parseMs, execMs: r.execMs});
			totalChars += s.src.length;
			totalParse += r.parseMs;
			totalExec += r.execMs;
			Sys.println(pad(s.name, 12) + ' chars=' + pad(Std.string(s.src.length), 7)
				+ ' parse=' + fmt(r.parseMs) + 'ms (' + fmt(s.src.length / (r.parseMs / 1000) / 1024) + ' KB/s)'
				+ ' exec=' + fmt(r.execMs) + 'ms');
		}

		Sys.println(pad("TOTAL", 12) + ' chars=' + pad(Std.string(totalChars), 7)
			+ ' parse=' + fmt(totalParse) + 'ms (' + fmt(totalChars / (totalParse / 1000) / 1024) + ' KB/s)'
			+ ' exec=' + fmt(totalExec) + 'ms');

		var json = buildJson(label, results, errors, totalChars, totalParse, totalExec);
		var path = 'bench/results/' + label + '.json';
		File.saveContent(path, json);
		Sys.println('wrote ' + path);
		if (errors.length > 0) Sys.println('WARNING: ' + errors.length + ' corpus script(s) errored');
	}

	/** Engine-equivalent parser configuration (see hscript.Config / HScript.hx). */
	static function newParser():Parser {
		var p = new Parser();
		p.allowTypes = true;
		p.allowJSON = true;
		p.allowMetadata = true;
		return p;
	}

	static function measure(name:String, src:String):{parseMs:Float, execMs:Float} {
		var origin = name + ".hx";

		// Parse measurement: fresh Parser per iteration, mirroring how hosts
		// parse each script file once at load time.
		var parseN = calibrate(function() newParser().parseString(src, origin), parseIters);
		var bestParse = Math.POSITIVE_INFINITY;
		for (_ in 0...ROUNDS) {
			var t0 = Sys.time();
			for (_ in 0...parseN)
				newParser().parseString(src, origin);
			var ms = (Sys.time() - t0) * 1000 / parseN;
			if (ms < bestParse) bestParse = ms;
		}

		// Execution measurement: a fresh Interp per iteration, mirroring one
		// script execution (callback dispatch, event handler run, ...).
		var ast = newParser().parseString(src, origin);
		var execN = calibrate(function() new Interp().execute(ast), execIters);
		var bestExec = Math.POSITIVE_INFINITY;
		for (_ in 0...ROUNDS) {
			var t0 = Sys.time();
			for (_ in 0...execN)
				new Interp().execute(ast);
			var ms = (Sys.time() - t0) * 1000 / execN;
			if (ms < bestExec) bestExec = ms;
		}
		return {parseMs: bestParse, execMs: bestExec};
	}

	/** Picks an iteration count so one round costs roughly ROUND_TARGET_MS. */
	static function calibrate(one:Void->Void, initial:Int):Int {
		var iters = initial;
		for (_ in 0...4) {
			var t0 = Sys.time();
			for (_ in 0...iters) one();
			var ms = (Sys.time() - t0) * 1000;
			if (ms <= 0) {
				iters = iters * 4;
				continue;
			}
			var scaled = Std.int(iters * ROUND_TARGET_MS / ms);
			if (scaled < MIN_ITERS) scaled = MIN_ITERS;
			if (scaled > MAX_ITERS) scaled = MAX_ITERS;
			if (scaled == iters || Math.abs(scaled - iters) <= Std.int(iters * 0.15)) return scaled;
			iters = scaled;
		}
		return iters;
	}

	static function compare(aLabel:String, bLabel:String) {
		var a = parseJson(File.getContent('bench/results/$aLabel.json'));
		var b = parseJson(File.getContent('bench/results/$bLabel.json'));
		Sys.println('comparing ' + aLabel + ' -> ' + bLabel + ' (negative % = faster)');
		Sys.println(pad("script", 12) + pad("parse A", 10) + pad("parse B", 10) + pad("parse %", 10)
			+ pad("exec A", 10) + pad("exec B", 10) + "exec %");
		for (sa in a.scripts) {
			var sb = null;
			for (x in b.scripts) if (x.name == sa.name) sb = x;
			if (sb == null) continue;
			var dp = (sb.parseMs - sa.parseMs) / sa.parseMs * 100;
			var de = (sb.execMs - sa.execMs) / sa.execMs * 100;
			Sys.println(pad(sa.name, 12) + pad(fmt(sa.parseMs), 10) + pad(fmt(sb.parseMs), 10) + pad(fmt(dp) + "%", 10)
				+ pad(fmt(sa.execMs), 10) + pad(fmt(sb.execMs), 10) + fmt(de) + "%");
		}
		var tp = (b.totalParseMs - a.totalParseMs) / a.totalParseMs * 100;
		var te = (b.totalExecMs - a.totalExecMs) / a.totalExecMs * 100;
		Sys.println(pad("TOTAL", 12) + pad(fmt(a.totalParseMs), 10) + pad(fmt(b.totalParseMs), 10) + pad(fmt(tp) + "%", 10)
			+ pad(fmt(a.totalExecMs), 10) + pad(fmt(b.totalExecMs), 10) + fmt(te) + "%");
	}

	static function buildJson(label:String, results:Array<{name:String, chars:Int, parseMs:Float, execMs:Float}>,
			errors:Array<String>, chars:Int, parseMs:Float, execMs:Float):String {
		var b = new StringBuf();
		b.add('{\n  "label": "' + label + '",\n');
		b.add('  "hscriptPos": ' + (#if hscriptPos "true" #else "false" #end) + ',\n');
		b.add('  "target": "' + targetName() + '",\n');
		b.add('  "totalChars": ' + chars + ',\n');
		b.add('  "totalParseMs": ' + parseMs + ',\n');
		b.add('  "totalExecMs": ' + execMs + ',\n');
		b.add('  "errors": [' + errors.map(function(e) return '"' + e.split('"').join("'") + '"').join(", ") + '],\n');
		b.add('  "scripts": [\n');
		for (i in 0...results.length) {
			var r = results[i];
			b.add('    {"name": "' + r.name + '", "chars": ' + r.chars + ', "parseMs": ' + r.parseMs + ', "execMs": ' + r.execMs + '}');
			if (i < results.length - 1) b.add(',');
			b.add('\n');
		}
		b.add('  ]\n}\n');
		return b.toString();
	}

	static function parseJson(s:String):{totalParseMs:Float, totalExecMs:Float, scripts:Array<{name:String, parseMs:Float, execMs:Float}>} {
		var scripts:Array<{name:String, parseMs:Float, execMs:Float}> = [];
		var totalParse = 0.0, totalExec = 0.0;
		for (line in s.split("\n")) {
			var l = StringTools.trim(line);
			if (l.indexOf('"name"') == 0 || l.indexOf('{"name"') == 0) {
				scripts.push({
					name: jsonStr(l, "name"),
					parseMs: jsonNum(l, "parseMs"),
					execMs: jsonNum(l, "execMs")
				});
			} else if (l.indexOf('"totalParseMs"') == 0)
				totalParse = jsonNum(l, "totalParseMs");
			else if (l.indexOf('"totalExecMs"') == 0)
				totalExec = jsonNum(l, "totalExecMs");
		}
		return {totalParseMs: totalParse, totalExecMs: totalExec, scripts: scripts};
	}

	static function jsonStr(line:String, key:String):String {
		var k = '"' + key + '": "';
		var i = line.indexOf(k);
		if (i < 0) return "";
		var j = line.indexOf('"', i + k.length);
		return line.substring(i + k.length, j);
	}

	static function jsonNum(line:String, key:String):Float {
		var k = '"' + key + '": ';
		var i = line.indexOf(k);
		if (i < 0) return 0;
		var j = i + k.length;
		var e = j;
		while (e < line.length) {
			var c = line.charCodeAt(e);
			if ((c >= 48 && c <= 57) || c == 45 || c == 46 || c == 101 || c == 69) e++; else break;
		}
		return Std.parseFloat(line.substring(j, e));
	}

	static function targetName():String {
		return #if interp "eval" #elseif eval "eval" #elseif cpp "cpp" #elseif hl "hl" #elseif js "js" #elseif neko "neko" #else "unknown" #end;
	}

	static function fmt(f:Float):String {
		return Std.string(Math.round(f * 1000) / 1000);
	}

	static function pad(s:String, n:Int):String {
		while (s.length < n) s += " ";
		return s;
	}
}
