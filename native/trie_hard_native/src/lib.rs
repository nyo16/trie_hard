use rustler::{Atom, Binary, Encoder, Env, NewBinary, ResourceArc, Term};
use std::sync::Mutex;

mod trie;
use trie::Trie;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
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
}

#[rustler::nif]
fn new_trie() -> ResourceArc<TrieResource> {
    ResourceArc::new(TrieResource::new())
}

#[rustler::nif]
fn insert(trie_resource: ResourceArc<TrieResource>, key: String, value: Term) -> Atom {
    match trie_resource.trie.lock() {
        Ok(mut trie) => {
            let hybrid_value = if let Ok(string_value) = value.decode::<String>() {
                // Zero-overhead path for strings
                HybridValue::String(string_value)
            } else {
                // Binary encode other terms using Erlang's external term format
                let owned_binary = value.to_binary();
                HybridValue::Binary(owned_binary.as_slice().to_vec())
            };

            trie.insert(&key, &hybrid_value);
            atoms::ok()
        }
        Err(_) => atoms::error(),
    }
}

#[rustler::nif]
fn get(env: Env, trie_resource: ResourceArc<TrieResource>, key: String) -> (Atom, Option<Term>) {
    match trie_resource.trie.lock() {
        Ok(trie) => match trie.get(&key) {
            Some(hybrid_value) => {
                let term = match hybrid_value {
                    HybridValue::String(s) => s.encode(env),
                    HybridValue::Binary(binary_data) => {
                        // Try to decode the external term format
                        // For now, just return the binary as-is to test the flow
                        // TODO: Implement proper external term decoding
                        let mut new_binary = NewBinary::new(env, binary_data.len());
                        new_binary.as_mut_slice().copy_from_slice(binary_data);
                        let binary: Binary = new_binary.into();
                        binary.to_term(env)
                    }
                };
                (atoms::ok(), Some(term))
            }
            None => (atoms::not_found(), None),
        },
        Err(_) => (atoms::error(), None),
    }
}

#[rustler::nif]
fn delete(trie_resource: ResourceArc<TrieResource>, key: String) -> Atom {
    match trie_resource.trie.lock() {
        Ok(mut trie) => {
            trie.delete(&key);
            atoms::ok()
        }
        Err(_) => atoms::error(),
    }
}

#[rustler::nif]
fn prefix_search(trie_resource: ResourceArc<TrieResource>, prefix: String) -> (Atom, bool) {
    match trie_resource.trie.lock() {
        Ok(trie) => (atoms::ok(), trie.prefix_search(&prefix)),
        Err(_) => (atoms::error(), false),
    }
}

#[rustler::nif]
fn auto_complete(
    trie_resource: ResourceArc<TrieResource>,
    prefix: String,
    max_results: usize,
) -> (Atom, Vec<String>) {
    match trie_resource.trie.lock() {
        Ok(trie) => {
            let results = trie.auto_complete(&prefix, max_results);
            (atoms::ok(), results)
        }
        Err(_) => (atoms::error(), Vec::new()),
    }
}

#[rustler::nif]
fn add_word_list(env: Env, trie_resource: ResourceArc<TrieResource>, words: Vec<String>) -> Atom {
    match trie_resource.trie.lock() {
        Ok(mut trie) => {
            let word_refs: Vec<&str> = words.iter().map(|s| s.as_str()).collect();
            trie.add_word_list(&word_refs, |word| {
                // For backward compatibility, we store the word as a string (zero overhead)
                HybridValue::String(word.to_string())
            });
            atoms::ok()
        }
        Err(_) => atoms::error(),
    }
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
