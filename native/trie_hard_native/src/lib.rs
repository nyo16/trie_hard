use rustler::{Atom, Binary, Encoder, Env, NewBinary, ResourceArc, Term};
use std::sync::{Mutex, MutexGuard, PoisonError};

mod trie;
use trie::Trie;

mod atoms {
    rustler::atoms! {
        ok,
        not_found,
    }
}

#[derive(Debug, Clone)]
enum HybridValue {
    String(String),  // Zero-overhead for strings
    Binary(Vec<u8>), // Binary-encoded for other terms
}

pub struct TrieResource {
    trie: Mutex<Trie<HybridValue>>,
}

impl TrieResource {
    fn new() -> Self {
        TrieResource {
            trie: Mutex::new(Trie::new()),
        }
    }

    /// A panic while holding the lock must not brick the trie forever: every
    /// mutation leaves the structure consistent, so the poisoned guard is safe.
    fn lock(&self) -> MutexGuard<'_, Trie<HybridValue>> {
        self.trie.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[rustler::nif]
fn new_trie() -> ResourceArc<TrieResource> {
    ResourceArc::new(TrieResource::new())
}

#[rustler::nif]
fn insert(trie_resource: ResourceArc<TrieResource>, key: String, value: Term) -> Atom {
    let hybrid_value = if let Ok(string_value) = value.decode::<String>() {
        // Zero-overhead path for strings
        HybridValue::String(string_value)
    } else {
        // Binary encode other terms using Erlang's external term format
        let owned_binary = value.to_binary();
        HybridValue::Binary(owned_binary.as_slice().to_vec())
    };

    trie_resource.lock().insert(&key, hybrid_value);
    atoms::ok()
}

#[rustler::nif]
fn get(env: Env, trie_resource: ResourceArc<TrieResource>, key: String) -> (Atom, Option<Term>) {
    match trie_resource.lock().get(&key) {
        Some(hybrid_value) => {
            let term = match hybrid_value {
                HybridValue::String(s) => s.encode(env),
                HybridValue::Binary(binary_data) => {
                    let mut new_binary = NewBinary::new(env, binary_data.len());
                    new_binary.as_mut_slice().copy_from_slice(binary_data);
                    let binary: Binary = new_binary.into();
                    binary.to_term(env)
                }
            };
            (atoms::ok(), Some(term))
        }
        None => (atoms::not_found(), None),
    }
}

#[rustler::nif]
fn delete(trie_resource: ResourceArc<TrieResource>, key: String) -> Atom {
    trie_resource.lock().delete(&key);
    atoms::ok()
}

#[rustler::nif]
fn prefix_search(trie_resource: ResourceArc<TrieResource>, prefix: String) -> (Atom, bool) {
    (atoms::ok(), trie_resource.lock().prefix_search(&prefix))
}

#[rustler::nif]
fn auto_complete(
    trie_resource: ResourceArc<TrieResource>,
    prefix: String,
    max_results: usize,
) -> (Atom, Vec<String>) {
    let results = trie_resource.lock().auto_complete(&prefix, max_results);
    (atoms::ok(), results)
}

#[rustler::nif]
fn count_prefix(trie_resource: ResourceArc<TrieResource>, prefix: String) -> usize {
    trie_resource.lock().count_prefix(&prefix)
}

#[rustler::nif]
#[allow(unused_variables)]
fn add_word_list(env: Env, trie_resource: ResourceArc<TrieResource>, words: Vec<String>) -> Atom {
    let word_refs: Vec<&str> = words.iter().map(|s| s.as_str()).collect();
    trie_resource.lock().add_word_list(&word_refs, |word| {
        // For backward compatibility, we store the word as a string (zero overhead)
        HybridValue::String(word.to_string())
    });
    atoms::ok()
}

#[allow(non_local_definitions)]
fn load(env: Env, _info: Term) -> bool {
    let _ = rustler::resource!(TrieResource, env);
    true
}

rustler::init!(
    "Elixir.TrieHard.Native",
    load = load,
    resources = [TrieResource]
);
