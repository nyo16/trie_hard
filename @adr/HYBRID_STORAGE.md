# ADR: Hybrid Storage for Arbitrary Erlang Terms

**Status:** Superseded (see "Outcome")  
**Date:** 2025-09-23  
**Decision Makers:** Development Team  

## Outcome

The `OwnedTerm` design below was never built: rustler 0.37 has no owned-term type that can
live in a resource across NIF calls. Holding a term would need its own `OwnedEnv` (a separate
process-independent heap per stored value), which is heavier than copying bytes.

- **0.2.7** shipped the "hybrid" variant: strings stored as Rust `String`s, every other term as
  external term format bytes produced inside the NIF, and `get/2` guessing whether a returned
  binary was ETF (`binary_to_term` inside `try/rescue`). The guess mis-decoded string values
  that happened to be valid ETF. It shipped as a 0.2.x release without a major version bump.
- **0.3.0** replaced it: every value is encoded with `:erlang.term_to_binary/1` in Elixir and
  stored as bytes (`Value(Arc<[u8]>)`); `add_word_list/2` stores a shared empty `Arc` meaning
  "the key is the value" (ETF is never empty, so no bytes are stored). `get/2` copies the bytes
  out after releasing the lock and decodes with `:erlang.binary_to_term(bin, [:safe])`.
  Encoding/decoding runs in yielding BIFs in the caller, not in the NIF, and no decode guessing
  remains.

The "Binary Encoding (Rejected)" alternative below is therefore what shipped. Its cost
estimates (2x memory, 3-5x CPU for strings) were not measured; the ETF overhead for a short
string is 6 bytes, and the 0.3.0 benchmarks are in the README.

## Context

The current TrieHard implementation only supports string values, limiting its utility for applications that need to store complex Erlang terms (atoms, tuples, maps, PIDs, etc.). Users have requested support for arbitrary data types while maintaining the high performance characteristics for string operations.

## Problem Statement

We need to extend TrieHard to support arbitrary Erlang terms without:
1. Degrading performance for existing string-based operations
2. Adding unnecessary complexity to the codebase  
3. Breaking existing APIs

## Decision

We will implement **Hybrid Storage** using Rustler's native `OwnedTerm` storage instead of binary encoding approaches.

## Architecture

### Current Implementation
```rust
pub struct TrieResource {
    trie: Mutex<Trie<String>>,
}
```

### Proposed Implementation
```rust
pub struct TrieResource {
    trie: Mutex<Trie<OwnedTerm>>,
}
```

## Alternatives Considered

### 1. Binary Encoding (Rejected)
```elixir
# Approach: Use :erlang.term_to_binary/1
binary_value = :erlang.term_to_binary("hello world")
```

**Rejected because:**
- **100% memory overhead** for strings (`"hello"` = 5 bytes → 10 bytes encoded)
- **3-5x CPU overhead** due to encode/decode on every operation
- Significant performance regression for string-heavy workloads

### 2. JSON Serialization (Rejected) 
```rust
pub struct TrieResource {
    trie: Mutex<Trie<serde_json::Value>>,
}
```

**Rejected because:**
- Type fidelity loss (atoms become strings)
- JSON overhead for simple values
- Doesn't support all Erlang term types

### 3. Hybrid Storage (Chosen)
```rust
use rustler::OwnedTerm;

pub struct TrieResource {
    trie: Mutex<Trie<OwnedTerm>>,
}
```

## Performance Analysis

### Memory Overhead Comparison
| Value Type | Current | Binary Encoding | Hybrid Storage |
|------------|---------|----------------|----------------|
| `"hello"`  | 5 bytes | 10 bytes (+100%) | 5 bytes (0%) |
| `:atom`    | N/A | 8 bytes | ~16 bytes |
| `{1, 2}`   | N/A | 12 bytes | ~32 bytes |

### CPU Overhead for Strings
| Operation | Current | Binary Encoding | Hybrid Storage |
|-----------|---------|----------------|----------------|
| Insert | ~50ns | ~300ns (+500%) | ~50ns (0%) |
| Get | ~50ns | ~300ns (+500%) | ~50ns (0%) |
| Autocomplete | ~50ns/item | ~300ns/item (+500%) | ~50ns/item (0%) |

## Implementation Plan

### Phase 1: Core Infrastructure
1. Update `TrieResource` to use `Trie<OwnedTerm>`
2. Modify all NIF functions to handle `OwnedTerm`
3. Update Elixir type specifications

### Phase 2: API Updates
1. Change `@type value :: String.t()` to `@type value :: term()`
2. Remove string-only validation guards
3. Update documentation and examples

### Phase 3: Testing & Migration
1. Comprehensive test suite for all Erlang term types
2. Performance regression testing
3. Migration guide for existing users

## Implementation Details

### Rust Changes (`lib.rs`)
```rust
use rustler::{Atom, Env, ResourceArc, Term, OwnedTerm};

pub struct TrieResource {
    trie: Mutex<Trie<OwnedTerm>>,
}

#[rustler::nif]
fn insert(trie_resource: ResourceArc<TrieResource>, key: String, value: Term) -> Atom {
    match trie_resource.trie.lock() {
        Ok(mut trie) => {
            let owned_value = value.to_owned();
            trie.insert(&key, &owned_value);
            atoms::ok()
        }
        Err(_) => atoms::error(),
    }
}

#[rustler::nif]  
fn get(trie_resource: ResourceArc<TrieResource>, key: String) -> (Atom, Option<Term>) {
    match trie_resource.trie.lock() {
        Ok(trie) => match trie.get(&key) {
            Some(owned_term) => (atoms::ok(), Some(owned_term.as_term())),
            None => (atoms::not_found(), None),
        },
        Err(_) => (atoms::error(), None),
    }
}
```

### Elixir Changes (`trie_hard.ex`)
```elixir
@type value :: term()  # Changed from String.t()

@spec insert(trie(), key(), value()) :: :ok | :error
def insert(trie, key, value) when is_binary(key) do  # Remove value type guard
  Native.insert(trie, key, value)
end
```

## Consequences

### Positive
- **Zero performance regression** for string operations
- **Full Erlang term support** (atoms, tuples, maps, PIDs, refs, binaries)
- **Memory efficient** - no encoding overhead
- **Type safe** - native Rustler term handling
- **Backward compatible** - existing string APIs unchanged

### Negative
- **Breaking change** - requires major version bump
- **Increased complexity** - need to handle all term types in tests
- **Memory usage** - complex terms have overhead vs strings
- **Documentation** - need comprehensive examples for all types

## Monitoring & Success Criteria

### Performance Benchmarks
- String operations maintain current performance (±5%)
- Memory usage for strings remains unchanged
- Complex term operations complete within acceptable bounds

### Functionality Tests
- All existing string-based functionality works unchanged
- Support for atoms, tuples, maps, lists, PIDs, references
- Proper serialization/deserialization round-trips

## Notes

This decision enables TrieHard to become a truly generic key-value trie for the Elixir ecosystem while maintaining its performance advantages for the common string use case.

**Risk Mitigation:**
- Comprehensive benchmark suite before release
- Gradual rollout with beta versions
- Clear migration documentation
- Performance regression alerts in CI