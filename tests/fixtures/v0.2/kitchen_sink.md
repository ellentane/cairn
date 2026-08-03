# Kitchen Sink

<button id="b">go</button>
<input id="i" value="7">
<p id="o"></p>

```cairn
let c = 0;
let s = "x" + "y";
let m = c - 1;
on click "#b" {
    inc c;
    extract_text "#o" to t;
    extract_value "#i" to v;
    if c == "2" {
        set_text s on "#o";
    } else {
        set_text v + "!" on "#o";
    }
    while m < 3 {
        inc m;
    }
    if m >= 2 { set_text "done" on "#o"; }
    if m <= 2 { add_class "le" on "#b"; }
    if c != "9" { toggle_class "le" on "#b"; }
    if m > 1 { remove_class "le" on "#b"; }
    add_class "k" on "#b";
    remove_class "k" on "#b";
    toggle_class "t" on "#b";
    set_text c on "#o";
}
```
