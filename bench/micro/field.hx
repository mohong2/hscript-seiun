var o = {x: 0, y: 0, name: "p"};
for (i in 0...3000) {
	o.x = o.x + i;
	o.y = o.x * 2 - i;
}
var s = o.name;
