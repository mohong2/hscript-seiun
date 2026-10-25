var acc = 0;
for (i in 0...2000) {
	acc = acc + i * 3 - (i % 7) + (i << 1) - (i >> 2);
	if (i % 2 == 0) acc = acc ^ (i & 15) else acc = acc | (i >>> 1);
}
var j = 0;
while (j < 1000) { acc += j; j++; }
