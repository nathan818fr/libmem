# LM_UnhookCode

```rust
pub fn LM_UnhookCode(from : lm_address_t, trampoline : (lm_address_t, lm_size_t)) -> Option<()>
```

# Description

Removes a hook/detour from the address `from`, restoring its old code saved in the `trampoline` in the calling process.

# Parameters

- from: the address where the hook will be removed.
- trampoline: the trampoline generated by the hook API, which contains the original code for the hooked function.

# Return Value

On success, it returns `Some(())`. On failure, it returns `None`.
