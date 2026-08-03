# My Document

<button id="btn">Click Me</button>
<p id="out">Status: 0</p>

<button id="chk">Check</button>
<p id="status">pending</p>

<div id="box">hover me</div>

<button id="inc">Count</button>
<p id="count">0</p>
<input id="name" value="world">

```cairn
let clicks = 0;
on click "#btn" {
    set_text "Status: 1" on "#out";
}
on click "#chk" {
    extract_text "#status" to s;
    if s == "done" {
        set_text "already done" on "#status";
    }
}
on hover "#box" {
    add_class "lit" on "#box";
}
on click "#inc" {
    inc clicks;
    if clicks == "3" {
        set_text "three clicks!" on "#out";
    } else {
        set_text clicks + " clicks" on "#out";
    }
}
on input "#name" {
    extract_value "#name" to n;
    set_text "hello " + n on "#out";
}
```
