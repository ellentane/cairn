# My Document

<button id="btn">Click Me</button>
<p id="out">Status: 0</p>

<button id="chk">Check</button>
<p id="status">pending</p>

<div id="box">hover me</div>

```cairn
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
```
