//! Layout dispatch: one `match` per operation over the two trie layouts,
//! which expose identical inherent APIs.

use crate::radix::RadixTrie;
use crate::sorted::SortedTrie;

/// A traversal exceeded its node-visit budget; retry with a larger one.
#[derive(Debug, PartialEq, Eq)]
pub struct OverBudget;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    /// One node per key byte, sorted child arrays.
    Sorted,
    /// Path-compressed: edges hold byte strings.
    Radix,
}

pub enum Store<T> {
    Sorted(SortedTrie<T>),
    Radix(RadixTrie<T>),
}

impl<T> Store<T> {
    pub fn new(layout: Layout) -> Self {
        match layout {
            Layout::Sorted => Store::Sorted(SortedTrie::new()),
            Layout::Radix => Store::Radix(RadixTrie::new()),
        }
    }

    pub fn insert(&mut self, key: &[u8], value: T) {
        match self {
            Store::Sorted(trie) => trie.insert(key, value),
            Store::Radix(trie) => trie.insert(key, value),
        }
    }

    pub fn get(&self, key: &[u8]) -> Option<&T> {
        match self {
            Store::Sorted(trie) => trie.get(key),
            Store::Radix(trie) => trie.get(key),
        }
    }

    pub fn delete(&mut self, key: &[u8]) -> bool {
        match self {
            Store::Sorted(trie) => trie.delete(key),
            Store::Radix(trie) => trie.delete(key),
        }
    }

    pub fn has_prefix(&self, prefix: &[u8]) -> bool {
        match self {
            Store::Sorted(trie) => trie.has_prefix(prefix),
            Store::Radix(trie) => trie.has_prefix(prefix),
        }
    }

    pub fn complete(
        &self,
        prefix: &[u8],
        max_results: usize,
        budget: usize,
    ) -> Result<Vec<Vec<u8>>, OverBudget> {
        match self {
            Store::Sorted(trie) => trie.complete(prefix, max_results, budget),
            Store::Radix(trie) => trie.complete(prefix, max_results, budget),
        }
    }

    pub fn count(&self, prefix: &[u8], budget: usize) -> Result<usize, OverBudget> {
        match self {
            Store::Sorted(trie) => trie.count(prefix, budget),
            Store::Radix(trie) => trie.count(prefix, budget),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::collections::BTreeMap;
    use std::ops::Bound;

    const UNLIMITED: usize = usize::MAX;

    impl<T> Store<T> {
        fn node_count(&self) -> usize {
            match self {
                Store::Sorted(trie) => trie.node_count(),
                Store::Radix(trie) => trie.node_count(),
            }
        }

        fn check_invariants(&self) {
            if let Store::Radix(trie) = self {
                trie.check_invariants();
            }
        }
    }

    #[derive(Debug, Clone)]
    enum Op {
        Insert(String, u32),
        Delete(String),
        Get(String),
        Count(String),
        Complete(String, usize),
    }

    fn key() -> impl Strategy<Value = String> {
        "[ab\u{e9}\u{1F980}]{0,5}"
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            3 => (key(), any::<u32>()).prop_map(|(k, v)| Op::Insert(k, v)),
            2 => key().prop_map(Op::Delete),
            1 => key().prop_map(Op::Get),
            1 => key().prop_map(Op::Count),
            1 => (key(), 0usize..8).prop_map(|(k, n)| Op::Complete(k, n)),
        ]
    }

    fn layout() -> impl Strategy<Value = Layout> {
        prop_oneof![Just(Layout::Sorted), Just(Layout::Radix)]
    }

    fn with_prefix<'a>(
        model: &'a BTreeMap<String, u32>,
        prefix: &'a str,
    ) -> impl Iterator<Item = &'a String> {
        model
            .range::<str, _>((Bound::Included(prefix), Bound::Unbounded))
            .map(|(k, _)| k)
            .take_while(move |k| k.starts_with(prefix))
    }

    fn words(results: Result<Vec<Vec<u8>>, OverBudget>) -> Vec<String> {
        results
            .unwrap()
            .into_iter()
            .map(|w| String::from_utf8(w).unwrap())
            .collect()
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(1024))]

        /// Both layouts behave exactly like an ordered map, and deleting every
        /// key returns the trie to a bare root.
        #[test]
        fn matches_btreemap_model(
            layout in layout(),
            ops in prop::collection::vec(op(), 0..64),
        ) {
            let mut store = Store::new(layout);
            let mut model = BTreeMap::new();
            for op in ops {
                match op {
                    Op::Insert(k, v) => {
                        store.insert(k.as_bytes(), v);
                        model.insert(k, v);
                    }
                    Op::Delete(k) => {
                        prop_assert_eq!(store.delete(k.as_bytes()), model.remove(&k).is_some());
                    }
                    Op::Get(k) => prop_assert_eq!(store.get(k.as_bytes()), model.get(&k)),
                    Op::Count(p) => {
                        let expected = with_prefix(&model, &p).count();
                        prop_assert_eq!(store.count(p.as_bytes(), UNLIMITED), Ok(expected));
                        prop_assert_eq!(store.has_prefix(p.as_bytes()), expected > 0);
                    }
                    Op::Complete(p, n) => {
                        // BTreeMap<String> order is byte order.
                        let expected: Vec<String> =
                            with_prefix(&model, &p).take(n).cloned().collect();
                        prop_assert_eq!(words(store.complete(p.as_bytes(), n, UNLIMITED)), expected);
                    }
                }
                store.check_invariants();
            }
            for k in model.keys() {
                prop_assert!(store.delete(k.as_bytes()));
                store.check_invariants();
            }
            prop_assert_eq!(store.node_count(), 1);
        }
    }
}
