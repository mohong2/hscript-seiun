/*
 * hscript-seiun shared test harness (MIT).
 * See LICENSE and NOTICE for details.
 */
package;

/**
 * Minimal assertion harness shared by every test-suite module.
 *
 * Contract for suite modules (owned by different workstreams):
 *
 *   class TestXxx {
 *       public static function run(h:TestHarness):Void {
 *           h.check(cond, "name");
 *           h.eq(got, want, "name");
 *       }
 *   }
 *
 * TestMain.runAll() calls every registered suite, so adding a suite never
 * requires editing another workstream's file.
 */
class TestHarness {
	public var passed:Int = 0;
	public var failed:Int = 0;
	public var failures:Array<String> = [];

	public function new() {}

	public function check(cond:Bool, name:String):Bool {
		if (cond) {
			passed++;
		} else {
			failed++;
			failures.push(name);
			trace('FAIL: ' + name);
		}
		return cond;
	}

	public function eq(got:Dynamic, want:Dynamic, name:String):Bool {
		return check(got == want, name + ' (got ' + Std.string(got) + ', want ' + Std.string(want) + ')');
	}

	public function neq(got:Dynamic, notWant:Dynamic, name:String):Bool {
		return check(got != notWant, name + ' (got ' + Std.string(got) + ', should differ)');
	}

	/** Reports a suite-level crash without aborting the whole run. */
	public function crashed(name:String, e:Dynamic):Void {
		failed++;
		failures.push(name);
		trace('CRASH: ' + name + ' -> ' + Std.string(e));
	}

	public function summary():String {
		return passed + ' passed, ' + failed + ' failed';
	}
}
