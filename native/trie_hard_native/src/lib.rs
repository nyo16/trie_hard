use rustler::{Binary, Encoder, Env, NewBinary, ResourceArc, Term};
use std::sync::{PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard, TryLockError};

mod trie;
mod value;

use trie::{OverBudget, Trie};
use value::Value;

mod atoms {
    rustler::atoms! {
        ok,
        not_found,
        self_key,
        dirty,
    }
}

/// Fast NIFs hand keys/prefixes longer than this to their dirty twin.
const FAST_MAX_KEY_BYTES: usize = 4 * 1024;
/// Fast NIFs hand values larger than this (copy cost) to their dirty twin.
const FAST_MAX_VALUE_BYTES: usize = 64 * 1024;
/// Node visits a fast traversal may make before handing off to its dirty twin.
const FAST_NODE_BUDGET: usize = 10_000;

/// How a NIF may wait for the trie lock.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// Normal scheduler: never block; return `:dirty` when contended or over budget.
    Fast,
    /// Dirty CPU scheduler: block on the lock, no budget.
    Blocking,
}

impl Mode {
    fn budget(self) -> usize {
        match self {
            Mode::Fast => FAST_NODE_BUDGET,
            Mode::Blocking => usize::MAX,
        }
    }

    fn too_large(self, bytes: usize, limit: usize) -> bool {
        self == Mode::Fast && bytes > limit
    }
}

pub struct TrieResource {
    trie: RwLock<Trie<Value>>,
}

#[rustler::resource_impl]
impl rustler::Resource for TrieResource {}

/// A panic while holding the lock must not brick the trie forever: every
/// mutation leaves the structure consistent, so a poisoned guard is safe.
impl TrieResource {
    fn read(&self, mode: Mode) -> Option<RwLockReadGuard<'_, Trie<Value>>> {
        match mode {
            Mode::Blocking => Some(self.trie.read().unwrap_or_else(PoisonError::into_inner)),
            Mode::Fast => match self.trie.try_read() {
                Ok(guard) => Some(guard),
                Err(TryLockError::Poisoned(poisoned)) => Some(poisoned.into_inner()),
                Err(TryLockError::WouldBlock) => None,
            },
        }
    }

    fn write(&self, mode: Mode) -> Option<RwLockWriteGuard<'_, Trie<Value>>> {
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

fn dirty(env: Env<'_>) -> Term<'_> {
    atoms::dirty().encode(env)
}

#[rustler::nif]
fn new_trie() -> ResourceArc<TrieResource> {
    ResourceArc::new(TrieResource {
        trie: RwLock::new(Trie::new()),
    })
}

fn insert_impl<'a>(
    env: Env<'a>,
    trie: &TrieResource,
    key: &str,
    etf: Binary,
    mode: Mode,
) -> Term<'a> {
    if mode.too_large(key.len(), FAST_MAX_KEY_BYTES)
        || mode.too_large(etf.len(), FAST_MAX_VALUE_BYTES)
    {
        return dirty(env);
    }
    let value = Value::Etf(etf.as_slice().into());
    match trie.write(mode) {
        Some(mut guard) => {
            guard.insert(key, value);
            atoms::ok().encode(env)
        }
        None => dirty(env),
    }
}

#[rustler::nif]
fn insert<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, key: &str, etf: Binary) -> Term<'a> {
    insert_impl(env, &trie, key, etf, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn insert_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    key: &str,
    etf: Binary,
) -> Term<'a> {
    insert_impl(env, &trie, key, etf, Mode::Blocking)
}

/// Returns `{:ok, etf}`, `:self_key`, `:not_found`, or `:dirty`.
fn get_impl<'a>(env: Env<'a>, trie: &TrieResource, key: &str, mode: Mode) -> Term<'a> {
    if mode.too_large(key.len(), FAST_MAX_KEY_BYTES) {
        return dirty(env);
    }
    // Clone the Arc under the read lock; copy the bytes after releasing it.
    let value = match trie.read(mode) {
        Some(guard) => guard.get(key).cloned(),
        None => return dirty(env),
    };
    match value {
        None => atoms::not_found().encode(env),
        Some(Value::SelfKey) => atoms::self_key().encode(env),
        Some(Value::Etf(bytes)) if mode.too_large(bytes.len(), FAST_MAX_VALUE_BYTES) => dirty(env),
        Some(Value::Etf(bytes)) => {
            let mut binary = NewBinary::new(env, bytes.len());
            binary.as_mut_slice().copy_from_slice(&bytes);
            (atoms::ok(), Binary::from(binary)).encode(env)
        }
    }
}

#[rustler::nif]
fn get<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, key: &str) -> Term<'a> {
    get_impl(env, &trie, key, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn get_dirty<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, key: &str) -> Term<'a> {
    get_impl(env, &trie, key, Mode::Blocking)
}

/// Returns whether the key existed, or `:dirty`.
fn delete_impl<'a>(env: Env<'a>, trie: &TrieResource, key: &str, mode: Mode) -> Term<'a> {
    if mode.too_large(key.len(), FAST_MAX_KEY_BYTES) {
        return dirty(env);
    }
    match trie.write(mode) {
        Some(mut guard) => guard.delete(key).encode(env),
        None => dirty(env),
    }
}

#[rustler::nif]
fn delete<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, key: &str) -> Term<'a> {
    delete_impl(env, &trie, key, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn delete_dirty<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, key: &str) -> Term<'a> {
    delete_impl(env, &trie, key, Mode::Blocking)
}

fn prefix_search_impl<'a>(env: Env<'a>, trie: &TrieResource, prefix: &str, mode: Mode) -> Term<'a> {
    if mode.too_large(prefix.len(), FAST_MAX_KEY_BYTES) {
        return dirty(env);
    }
    match trie.read(mode) {
        Some(guard) => guard.prefix_search(prefix).encode(env),
        None => dirty(env),
    }
}

#[rustler::nif]
fn prefix_search<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, prefix: &str) -> Term<'a> {
    prefix_search_impl(env, &trie, prefix, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prefix_search_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: &str,
) -> Term<'a> {
    prefix_search_impl(env, &trie, prefix, Mode::Blocking)
}

fn auto_complete_impl<'a>(
    env: Env<'a>,
    trie: &TrieResource,
    prefix: &str,
    max_results: usize,
    mode: Mode,
) -> Term<'a> {
    if mode.too_large(prefix.len(), FAST_MAX_KEY_BYTES) {
        return dirty(env);
    }
    let results = match trie.read(mode) {
        Some(guard) => guard.auto_complete(prefix, max_results, mode.budget()),
        None => return dirty(env),
    };
    match results {
        Ok(words) => words.encode(env),
        Err(OverBudget) => dirty(env),
    }
}

#[rustler::nif]
fn auto_complete<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: &str,
    max_results: usize,
) -> Term<'a> {
    auto_complete_impl(env, &trie, prefix, max_results, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn auto_complete_dirty<'a>(
    env: Env<'a>,
    trie: ResourceArc<TrieResource>,
    prefix: &str,
    max_results: usize,
) -> Term<'a> {
    auto_complete_impl(env, &trie, prefix, max_results, Mode::Blocking)
}

fn count_prefix_impl<'a>(env: Env<'a>, trie: &TrieResource, prefix: &str, mode: Mode) -> Term<'a> {
    if mode.too_large(prefix.len(), FAST_MAX_KEY_BYTES) {
        return dirty(env);
    }
    let count = match trie.read(mode) {
        Some(guard) => guard.count_prefix(prefix, mode.budget()),
        None => return dirty(env),
    };
    match count {
        Ok(count) => count.encode(env),
        Err(OverBudget) => dirty(env),
    }
}

#[rustler::nif]
fn count_prefix<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, prefix: &str) -> Term<'a> {
    count_prefix_impl(env, &trie, prefix, Mode::Fast)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn count_prefix_dirty<'a>(env: Env<'a>, trie: ResourceArc<TrieResource>, prefix: &str) -> Term<'a> {
    count_prefix_impl(env, &trie, prefix, Mode::Blocking)
}

/// Always dirty: the Elixir side chunks the list to bound the write-lock hold.
#[rustler::nif(schedule = "DirtyCpu")]
fn add_word_list(trie: ResourceArc<TrieResource>, words: Vec<&str>) -> rustler::Atom {
    let mut guard = trie.trie.write().unwrap_or_else(PoisonError::into_inner);
    guard.add_word_list(&words, |_| Value::SelfKey);
    atoms::ok()
}

rustler::init!("Elixir.TrieHard.Native");
