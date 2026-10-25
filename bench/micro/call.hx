function fib(n) return n < 2 ? n : fib(n - 1) + fib(n - 2);
var t = 0;
for (k in 0...4) t += fib(12);
function add3(a, b, c) return a + b + c;
for (k in 0...2000) t += add3(k, k + 1, k + 2);
