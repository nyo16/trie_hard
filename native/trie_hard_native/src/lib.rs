use rustler::{Atom, Binary, Encoder, Env, Error, NewBinary, NifResult, ResourceArc, Term};
use std::sync::{PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard, TryLockError};

mod radix;
mod sorted;
mod store;
mod value;

use store::{Budget, Layout, OverBudget, Store};
use value::Value;

mod atoms {
    rustler::atoms! {
        ok,
        not_found,
        self_key,
        dirty,
        busy,
        sorted,
        radix,
    }
}

/// Fast NIFs hand keys/prefixes longer than this to their dirty twin.
const FAST_MAX_KEY_BYTES: usize = 4 * 1024;
/// Fast NIFs hand values larger than this (copy cost) to their dirty twin.
const FAST_MAX_VALUE_BYTES: usize = 64 * 1024;
/// Node visits a fast traversal may make before handing off to its dirty twin.
const FAST_NODE_BUDGET: usize = 10_000;
/// Bytes a fast operation may copy (edge labels, results, split/merged edges)
/// before handing off to its dirty twin.
const FAST_BYTE_BUDGET: usize = 64 * 1024;

/// How a NIF may wait for the trie lock.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    /// Normal scheduler: never block. Returns `:busy` when the lock is
    /// contended and `:dirty` when the work exceeds the fast-path bounds.
    Fast,
    /// Dirty CPU scheduler: block on the lock, no budget.
    Blocking,
}

impl Mode {
    fn budget(self) -> Budget {
        match self {
            Mode::Fast => Budget::new(FAST_NODE_BUDGET, FAST_BYTE_BUDGET),
            Mode::Blocking => Budget::UNLIMITED,
        }
    }

    fn too_large(self, bytes: usize, limit: usize) -> bool {
        self == Mode::Fast && bytes > limit
    }
}

pub struct TrieResource {
    trie: RwLock<Store<Value>>,
}

#[rustler::resource_impl]
impl rustler::Resource for TrieResource {}

/// A panic while holding the lock must not brick the trie forever: every
/// mutation leaves the structure consistent, so a poisoned guard is safe.
impl TrieResource {
    fn read(&self, mode: Mode) -> Option<RwLockReadGuard<'_, Store<Value>>> {
        match mode {
            Mode::Blocking => Some(self.trie.read().unwrap_or_else(PoisonError::into_inner)),
            Mode::Fast => match self.trie.try_read() {
                Ok(guard) => Some(guard),
                Err(TryLockError::Poisoned(poisoned)) => Some(poisoned.into_inner()),
                Err(TryLockError::WouldBlock) => None,
            },
        }
    }

    fn write(&self, mode: Mode) -> Option<RwLockWriteGuard<'_, Store<Value>>> {
        match mode {
            Mode::Blocking => Some(self.trie.write().unwrap_or_else(PoisonError::into_inner)),
            Mode::Fast => match self.trie.try_write() {
                Ok(guard) => Some(guard),
                Err(TryLockError::Poisoned(poisoned)) => Some(poisoned.into_inner()),
                Err(TryLockError::WouldBlock) => None,
            },
        }
    }
}

/// The work exceeds the fast-path bounds: the caller retries the dirty twin.
fn dirty(env: Env<'_>) -> Term<'_> {
    atoms::dirty().encode(env)
}

/// The lock is held by a writer (or a writer is queued): the caller yields
/// and retries the fast NIF, so waiting never occupies a dirty scheduler.
fn busy(env: Env<'_>) -> Term<'_> {
    atoms::busy().encode(env)
}

/// Keys arrive as raw binaries so the size gate runs before UTF-8
/// validation: decoding `&str` would scan the whole input on the normal
/// scheduler first. `Ok(None)` means "too large for this mode".
fn key_bytes<'k>(key: &'k Binary, mode: Mode) -> NifResult<Option<&'k [u8]>> {
    if mode.too_large(key.len(), FAST_MAX_KEY_BYTES) {
        return Ok(None);
    }
    std::str::from_utf8(key.as_slice()).map_err(|_| Error::BadArg)?;
    Ok(Some(key.as_slice()))
}

/// Completions are valid UTF-8 by construction (prefixes of UTF-8 keys
/// extended to full keys), so they are emitted as binaries without re-checking.
fn encode_words<'a>(env: Env<'a>, words: &[Vec<u8>]) -> Term<'a> {
    let terms: Vec<Term<'a>> = words
        .iter()
        .map(|word| {
            let mut binary = NewBinary::new(env, word.len());
            binary.as_mut_slice().copy_from_slice(word);
            Binary::from(binary).to_term(env)
        })
        .collect();
    terms.encode(env)
}

/// `layout` is `:sorted` or `:radix` (validated in Elixir; anything else is badarg).
#[rustler::nif]
fn new_trie(layout: Atom) -> NifResult<ResourceArc<TrieResource>> {
    let layout = if layout == atoms::sorted() {
        Layout::Sorted
    } else if layout == atoms::radix() {
        Layout::Radix
    } else {
        return Err(Error::BadArg);
    };
    Ok(ResourceArc::new(TrieResource {
        trie: RwLock::new(Store::new(layout)),
    }))
}

fn insert_impl<'a>(
    env: Env<'a>,
    trie: &TrieResource,
    key: Binary,
    etf: Binary,
    mode: Mode,
) -> NifResult<Term<'a>> {
    let Some(key) = key_bytes(&key, mode)? else {
        return Ok(dirty(env));
    };
    if mode.too_large(etf.len(), FAST_MAX_VALUE_BYTES) {
        return Ok(dirty(env));
    }
    let value = Value::etf(etf.as_slice());
    let Some(mut guard) = trie.write(mode) else {
        return Ok(busy(env));
    };
    Ok(match guard.insert(key, value, mode.budget()) {
        Ok(()) => atoms::ok().encode(env),
        Err(OverBudget) => dirty(env),
    })
}

#[rustler::nif]
fn insert<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    key: Binary,
    etf: Binary,
) -> NifResult<Term<'a>> {
    insert_impl(env, &trie, key, etf, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn insert_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    key: Binary,
    etf: Binary,
) -> NifResult<Term<'a>> {
    insert_impl(env, &trie, key, etf, Mode::Blocking)
}

/// Returns `{:ok, etf}`, `:self_key`, `:not_found`, or `:dirty`.
fn get_impl<'a>(env: Env<'a>, trie: &TrieResource, key: Binary, mode: Mode) -> NifResult<Term<'a>> {
    let Some(key) = key_bytes(&key, mode)? else {
        return Ok(dirty(env));
    };
    // Clone the Arc under the read lock; copy the bytes after releasing it.
    let value = match trie.read(mode) {
        Some(guard) => guard.get(key).cloned(),
        None => return Ok(busy(env)),
    };
    let Some(value) = value else {
        return Ok(atoms::not_found().encode(env));
    };
    Ok(match value.etf_bytes() {
        None => atoms::self_key().encode(env),
        Some(bytes) if mode.too_large(bytes.len(), FAST_MAX_VALUE_BYTES) => dirty(env),
        Some(bytes) => {
            let mut binary = NewBinary::new(env, bytes.len());
            binary.as_mut_slice().copy_from_slice(bytes);
            (atoms::ok(), Binary::from(binary)).encode(env)
        }
    })
}

#[rustler::nif]
fn get<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, key: Binary) -> NifResult<Term<'a>> {
    get_impl(env, &trie, key, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn get_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    key: Binary,
) -> NifResult<Term<'a>> {
    get_impl(env, &trie, key, Mode::Blocking)
}

/// Returns whether the key existed, or `:dirty`.
fn delete_impl<'a>(
    env: Env<'a>,
    trie: &TrieResource,
    key: Binary,
    mode: Mode,
) -> NifResult<Term<'a>> {
    let Some(key) = key_bytes(&key, mode)? else {
        return Ok(dirty(env));
    };
    let Some(mut guard) = trie.write(mode) else {
        return Ok(busy(env));
    };
    Ok(match guard.delete(key, mode.budget()) {
        Ok(existed) => existed.encode(env),
        Err(OverBudget) => dirty(env),
    })
}

#[rustler::nif]
fn delete<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, key: Binary) -> NifResult<Term<'a>> {
    delete_impl(env, &trie, key, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn delete_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    key: Binary,
) -> NifResult<Term<'a>> {
    delete_impl(env, &trie, key, Mode::Blocking)
}

fn prefix_search_impl<'a>(
    env: Env<'a>,
    trie: &TrieResource,
    prefix: Binary,
    mode: Mode,
) -> NifResult<Term<'a>> {
    let Some(prefix) = key_bytes(&prefix, mode)? else {
        return Ok(dirty(env));
    };
    Ok(match trie.read(mode) {
        Some(guard) => guard.has_prefix(prefix).encode(env),
        None => busy(env),
    })
}

#[rustler::nif]
fn prefix_search<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: Binary,
) -> NifResult<Term<'a>> {
    prefix_search_impl(env, &trie, prefix, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prefix_search_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: Binary,
) -> NifResult<Term<'a>> {
    prefix_search_impl(env, &trie, prefix, Mode::Blocking)
}

fn auto_complete_impl<'a>(
    env: Env<'a>,
    trie: &TrieResource,
    prefix: Binary,
    max_results: usize,
    mode: Mode,
) -> NifResult<Term<'a>> {
    let Some(prefix) = key_bytes(&prefix, mode)? else {
        return Ok(dirty(env));
    };
    let results = match trie.read(mode) {
        Some(guard) => guard.complete(prefix, max_results, mode.budget()),
        None => return Ok(busy(env)),
    };
    Ok(match results {
        Ok(words) => encode_words(env, &words),
        Err(OverBudget) => dirty(env),
    })
}

#[rustler::nif]
fn auto_complete<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: Binary,
    max_results: usize,
) -> NifResult<Term<'a>> {
    auto_complete_impl(env, &trie, prefix, max_results, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn auto_complete_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: Binary,
    max_results: usize,
) -> NifResult<Term<'a>> {
    auto_complete_impl(env, &trie, prefix, max_results, Mode::Blocking)
}

fn count_prefix_impl<'a>(
    env: Env<'a>,
    trie: &TrieResource,
    prefix: Binary,
    mode: Mode,
) -> NifResult<Term<'a>> {
    let Some(prefix) = key_bytes(&prefix, mode)? else {
        return Ok(dirty(env));
    };
    let count = match trie.read(mode) {
        Some(guard) => guard.count(prefix, mode.budget()),
        None => return Ok(busy(env)),
    };
    Ok(match count {
        Ok(count) => count.encode(env),
        Err(OverBudget) => dirty(env),
    })
}

#[rustler::nif]
fn count_prefix<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: Binary,
) -> NifResult<Term<'a>> {
    count_prefix_impl(env, &trie, prefix, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn count_prefix_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: Binary,
) -> NifResult<Term<'a>> {
    count_prefix_impl(env, &trie, prefix, Mode::Blocking)
}

/// Always dirty: the Elixir side encodes values and chunks the pairs to bound
/// the write-lock hold. Values are copied before the lock is taken.
#[rustler::nif(schedule = "DirtyCpu")]
fn insert_many(trie: ResourceArc<TrieResource>, pairs: Vec<(&str, Binary)>) -> Atom {
    let entries: Vec<(&str, Value)> = pairs
        .into_iter()
        .map(|(key, etf)| (key, Value::etf(etf.as_slice())))
        .collect();
    let mut guard = trie.trie.write().unwrap_or_else(PoisonError::into_inner);
    for (key, value) in entries {
        insert_unlimited(&mut guard, key, value);
    }
    atoms::ok()
}

/// Always dirty: the Elixir side chunks the list to bound the write-lock hold.
#[rustler::nif(schedule = "DirtyCpu")]
fn add_word_list(trie: ResourceArc<TrieResource>, words: Vec<&str>) -> Atom {
    let mut guard = trie.trie.write().unwrap_or_else(PoisonError::into_inner);
    for word in words {
        insert_unlimited(&mut guard, word, Value::self_key());
    }
    atoms::ok()
}

fn insert_unlimited(store: &mut Store<Value>, key: &str, value: Value) {
    store
        .insert(key.as_bytes(), value, Budget::UNLIMITED)
        .expect("an unlimited budget cannot be exceeded");
}

rustler::init!("Elixir.TrieHard.Native");

#[cfg(test)]
mod tests {
    use super::*;

    fn resource() -> TrieResource {
        TrieResource {
            trie: RwLock::new(Store::new(Layout::Radix)),
        }
    }

    #[test]
    fn fast_lock_attempts_never_block() {
        let trie = resource();
        {
            let _writer = trie.write(Mode::Blocking).unwrap();
            assert!(trie.read(Mode::Fast).is_none());
            assert!(trie.write(Mode::Fast).is_none());
        }
        let _reader = trie.read(Mode::Fast).unwrap();
        assert!(trie.read(Mode::Fast).is_some());
        assert!(trie.write(Mode::Fast).is_none());
    }

    #[test]
    fn poisoned_lock_is_recovered() {
        let trie = std::sync::Arc::new(resource());
        let poisoner = std::sync::Arc::clone(&trie);
        let result = std::thread::spawn(move || {
            let mut guard = poisoner.write(Mode::Blocking).unwrap();
            insert_unlimited(&mut guard, "k", Value::self_key());
            panic!("poison the lock");
        })
        .join();
        assert!(result.is_err());
        assert!(trie.trie.is_poisoned());

        assert!(trie.read(Mode::Fast).unwrap().get(b"k").is_some());
        assert!(trie.read(Mode::Blocking).unwrap().get(b"k").is_some());
        let mut guard = trie.write(Mode::Fast).unwrap();
        assert_eq!(guard.delete(b"k", Mode::Fast.budget()), Ok(true));
    }

    #[test]
    fn size_gates_apply_only_to_fast_mode() {
        assert!(!Mode::Fast.too_large(FAST_MAX_KEY_BYTES, FAST_MAX_KEY_BYTES));
        assert!(Mode::Fast.too_large(FAST_MAX_KEY_BYTES + 1, FAST_MAX_KEY_BYTES));
        assert!(!Mode::Blocking.too_large(usize::MAX, FAST_MAX_KEY_BYTES));
        assert_eq!(Mode::Blocking.budget(), Budget::UNLIMITED);
    }
}
