/*
 * hscript-seiun benchmark corpus (MIT).
 *
 * Representative HScript sources used by bench/Bench.hx. Generated
 * programmatically so the corpus is deterministic and needs no file IO.
 */
package;

typedef CorpusScript = {name:String, src:String};

class Corpus {
	public static function all():Array<CorpusScript> {
		return [
			{name: "gameplay", src: gameplay()},
			{name: "classheavy", src: classheavy()},
			{name: "expression", src: expression()},
			{name: "shapes", src: shapes()}
		];
	}

	/** Typical FNF state/script shape: callbacks, objects, arrays, switches. */
	static function gameplay():String {
		var b = new StringBuf();
		b.add('var score = 0;\n');
		b.add('var combo = 0;\n');
		b.add('var notes = [];\n');
		b.add('var data = {speed: 1.0, health: 1.0, name: "bf", tags: ["a", "b"]};\n');
		for (i in 0...40) {
			b.add('function onCreatePost$i() {\n');
			b.add('\tvar n = $i;\n');
			b.add('\tif (n % 2 == 0) { score += n; } else { combo += 1; }\n');
			b.add('\tnotes.push({id: n, lane: n % 4, hit: n > 20});\n');
			b.add('\treturn n * 2;\n');
			b.add('}\n');
		}
		for (i in 0...40)
			b.add('onCreatePost$i();\n');
		b.add('for (i in 0...30) {\n');
		b.add('\tvar n = notes[i % notes.length];\n');
		b.add('\tswitch (n.lane) {\n');
		b.add('\t\tcase 0: score += 1;\n');
		b.add('\t\tcase 1: score += 2;\n');
		b.add('\t\tcase 2: score += 3;\n');
		b.add('\t\tdefault: score -= 1;\n');
		b.add('\t}\n');
		b.add('\tif (n.hit && n.id > 3) combo += 1;\n');
		b.add('}\n');
		b.add('function onUpdate(elapsed) {\n');
		b.add('\tvar t = elapsed * data.speed;\n');
		b.add('\tdata.health = data.health + (t > 0.5 ? -0.001 : 0.001);\n');
		b.add('\treturn data.health;\n');
		b.add('}\n');
		b.add('var summary = "score=" + score + ",combo=" + combo + ",notes=" + notes.length;\n');
		return b.toString();
	}

	/** Script classes, inheritance, statics, method dispatch. */
	static function classheavy():String {
		var b = new StringBuf();
		b.add('class Entity {\n');
		b.add('\tpublic var x:Float = 0;\n');
		b.add('\tpublic var y:Float = 0;\n');
		b.add('\tpublic var alive:Bool = true;\n');
		b.add('\tstatic var instances:Int = 0;\n');
		b.add('\tpublic function new() { instances++; }\n');
		b.add('\tpublic function move(dx, dy):Float { x += dx; y += dy; return x + y; }\n');
		b.add('\tpublic function update(dt) { move(dt, dt * 0.5); }\n');
		b.add('}\n');
		b.add('class Player extends Entity {\n');
		b.add('\tvar speed = 1.5;\n');
		b.add('\tpublic function update(dt) { move(dt * speed, 0); }\n');
		b.add('\tpublic function jump():Float { alive = true; return speed * 10; }\n');
		b.add('}\n');
		b.add('class Projectile extends Entity {\n');
		b.add('\tvar damage = 3;\n');
		b.add('\tpublic function hit(target) { target.alive = false; return damage; }\n');
		b.add('}\n');
		b.add('var total = 0.0;\n');
		b.add('for (i in 0...60) {\n');
		b.add('\tvar p = new Player(); p.x = i; p.y = i * 2;\n');
		b.add('\tvar q = new Projectile(); q.x = i + 1; q.y = i;\n');
		b.add('\tp.update(0.016);\n');
		b.add('\ttotal += p.jump() + q.hit(p);\n');
		b.add('}\n');
		b.add('var aliveCount = 0;\n');
		b.add('var e = new Entity(); e.x = 1; e.y = 2;\n');
		b.add('for (i in 0...20) { e.update(i); if (e.alive) aliveCount++; }\n');
		return b.toString();
	}

	/** Tight numeric/operator loops: stresses interpreter dispatch. */
	static function expression():String {
		var b = new StringBuf();
		b.add('var acc = 0;\n');
		b.add('var f = 1.5;\n');
		b.add('for (i in 0...500) {\n');
		b.add('\tacc = acc + i * 3 - (i % 7) + (i << 1) - (i >> 2);\n');
		b.add('\tif (i % 2 == 0) acc = acc ^ (i & 15) else acc = acc | (i >>> 1);\n');
		b.add('\tf = f * 1.0001 + (i > 100 ? 0.5 : -0.25);\n');
		b.add('\tif (f > 1.6) acc = acc + (i % 13);\n');
		b.add('}\n');
		b.add('function fib(n) return n < 2 ? n : fib(n - 1) + fib(n - 2);\n');
		b.add('var fv = fib(14);\n');
		b.add('var arr = [1, 2, 3, 4, 5, 6, 7, 8];\n');
		b.add('var sum = 0;\n');
		b.add('for (i in 0...200) { for (v in arr) sum += v * (i % 3 + 1); }\n');
		b.add('var nested = [[1, 2], [3, 4], [5, 6]];\n');
		b.add('for (row in nested) { for (v in row) sum += v; }\n');
		return b.toString();
	}

	/** Many distinct small constructs: stresses tokenizer + parser breadth. */
	static function shapes():String {
		var b = new StringBuf();
		for (i in 0...50) {
			b.add('var o$i = {a: $i, b: "s$i", c: [$i, $i + 1], d: {e: $i * 2}};\n');
			b.add('var s$i = "value=" + o$i.a + ";tag=" + o$i.b;\n');
			b.add('function h$i(x:Int, ?y:Int, z:Int = 3):Int {\n');
			b.add('\tvar t = x * $i + y + z;\n');
			b.add('\treturn t > 10 ? t - 10 : t + 10;\n');
			b.add('}\n');
			b.add('try { var r$i = h$i($i, $i, $i + 1); } catch (e:Dynamic) { trace(e); }\n');
		}
		b.add('var m = ["k1" => 1, "k2" => 2];\n');
		b.add('var list = [for (i in 0...20) i * i];\n');
		b.add('var idx = 0;\n');
		b.add('while (idx < list.length) { idx++; }\n');
		b.add('do { idx--; } while (idx > 0);\n');
		return b.toString();
	}
}
