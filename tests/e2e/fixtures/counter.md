# Counter

<button id="inc">increment</button>
<button id="btn">set status</button>
<input type="checkbox" id="chk">
<p id="out"></p>
<p id="status"></p>

```cairn
let c = 0;
on click "#inc" {
    inc c;
    if c == "3" {
        set_text "three clicks!" on "#out";
    } else {
        set_text c + " clicks" on "#out";
    }
}
on click "#btn" {
    set_text "Status: 1" on "#out";
}
on change "#chk" {
    set_text "pending" on "#status";
}
```
