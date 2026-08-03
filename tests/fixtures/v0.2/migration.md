# Migration

```cairn
on click "#go" {
    extract_text "#src" to v;
    if v == "05" {
        set_text "matched" on "#dst";
    }
}
```
