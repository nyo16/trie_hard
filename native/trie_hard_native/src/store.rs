//! Layout dispatch: one `match` per operation over the two trie layouts,
//! which expose identical inherent APIs.

use crate::radix::RadixTrie;
use crate::sorted::SortedTrie;

/// An operation exceeded its [`Budget`]; retry with a larger one.
#[derive(Debug, PartialEq, Eq)]
pub struct OverBudget;

/// Work allowance for one operation: node visits and bytes copied.
///
/// Node visits alone do not bound the work: one radix edge can hold an
/// arbitrarily long key, so copying it costs bytes, not nodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Budget {
    nodes: usize,
    bytes: usize,
}

impl Budget {
    pub const UNLIMITED: Budget = Budget::new(usize::MAX, usize::MAX);

    pub const fn new(nodes: usize, bytes: usize) -> Self {
        Budget { nodes, bytes }
    }

    /// Charges one node visit that copies `bytes` bytes.
    pub fn visit(&mut self, bytes: usize) -> Result<(), OverBudget> {
        self.nodes = self.nodes.checked_sub(1).ok_or(OverBudget)?;
        self.copy(bytes)
    }

    /// Charges `bytes` copied bytes.
    pub fn copy(&mut self, bytes: usize) -> Result<(), OverBudget> {
        self.bytes = self.bytes.checked_sub(bytes).ok_or(OverBudget)?;
        Ok(())
    }
}

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

    /// `Err(OverBudget)` leaves the trie unchanged (radix only: splitting a
    /// long edge costs its length in bytes).
    pub fn insert(&mut self, key: &[u8], value: T, budget: Budget) -> Result<(), OverBudget> {
        match self {
            Store::Sorted(trie) => {
                trie.insert(key, value);
                Ok(())
            }
            Store::Radix(trie) => trie.insert(key, value, budget),
        }
    }

    pub fn get(&self, key: &[u8]) -> Option<&T> {
        match self {
            Store::Sorted(trie) => trie.get(key),
            Store::Radix(trie) => trie.get(key),
        }
    }

    /// Whether the key existed. `Err(OverBudget)` leaves the trie unchanged
    /// (radix only: merging edges costs their length in bytes).
    pub fn delete(&mut self, key: &[u8], budget: Budget) -> Result<bool, OverBudget> {
        match self {
            Store::Sorted(trie) => Ok(trie.delete(key)),
            Store::Radix(trie) => trie.delete(key, budget),
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
        budget: Budget,
    ) -> Result<Vec<Vec<u8>>, OverBudget> {
        match self {
            Store::Sorted(trie) => trie.complete(prefix, max_results, budget),
            Store::Radix(trie) => trie.complete(prefix, max_results, budget),
        }
    }

    pub fn count(&self, prefix: &[u8], budget: Budget) -> Result<usize, OverBudget> {
        match self {
            Store::Sorted(trie) => trie.count(prefix, budget),
            Store::Radix(trie) => trie.count(prefix, budget),
        }
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    /// Runs `f` on a thread with a 256 KiB stack (smaller than a BEAM dirty
    /// scheduler's), so any recursion over deep tries overflows and fails.
    pub fn on_small_stack(f: impl FnOnce() + Send + 'static) {
        std::thread::Builder::new()
            .stack_size(256 * 1024)
            .spawn(f)
            .expect("spawn test thread")
            .join()
            .expect("test thread panicked");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::collections::BTreeMap;
    use std::ops::Bound;

    const UNLIMITED: Budget = Budget::UNLIMITED;

    impl<T> Store<T> {
        fn node_count(&self) -> usize {
            match self {
                Store::Sorted(trie) => trie.node_count(),
                Store::Radix(trie) => trie.node_count(),
            }
        }

        fn check_invariants(&self) {
            match self {
                Store::Sorted(trie) => trie.check_invariants(),
                Store::Radix(trie) => trie.check_invariants(),
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
        TightInsert(String, u32, usize),
        TightDelete(String, usize),
        TightComplete(String, usize, usize, usize),
    }

    /// é/è and 🦀/🦁 share leading UTF-8 bytes, so radix edges split and merge
    /// in the middle of a character.
    fn key() -> impl Strategy<Value = String> {
        "[ab\u{e8}\u{e9}\u{1F980}\u{1F981}]{0,5}"
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            3 => (key(), any::<u32>()).prop_map(|(k, v)| Op::Insert(k, v)),
            2 => key().prop_map(Op::Delete),
            1 => key().prop_map(Op::Get),
            1 => key().prop_map(Op::Count),
            1 => (key(), 0usize..8).prop_map(|(k, n)| Op::Complete(k, n)),
            1 => (key(), any::<u32>(), 0usize..8).prop_map(|(k, v, b)| Op::TightInsert(k, v, b)),
            1 => (key(), 0usize..8).prop_map(|(k, b)| Op::TightDelete(k, b)),
            1 => (key(), 0usize..8, 0usize..12, 0usize..40)
                .prop_map(|(k, n, nodes, bytes)| Op::TightComplete(k, n, nodes, bytes)),
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
                        store.insert(k.as_bytes(), v, UNLIMITED).unwrap();
                        model.insert(k, v);
                    }
                    Op::Delete(k) => {
                        prop_assert_eq!(store.delete(k.as_bytes(), UNLIMITED), Ok(model.remove(&k).is_some()));
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
                    // Over budget, writes must leave the trie untouched (checked by
                    // every later op against the model) and reads must fail whole.
                    Op::TightInsert(k, v, bytes) => {
                        if store.insert(k.as_bytes(), v, Budget::new(usize::MAX, bytes)).is_ok() {
                            model.insert(k, v);
                        }
                    }
                    Op::TightDelete(k, bytes) => {
                        if let Ok(existed) = store.delete(k.as_bytes(), Budget::new(usize::MAX, bytes)) {
                            prop_assert_eq!(existed, model.remove(&k).is_some());
                        }
                    }
                    Op::TightComplete(p, n, nodes, bytes) => {
                        if let Ok(got) = store.complete(p.as_bytes(), n, Budget::new(nodes, bytes)) {
                            let expected: Vec<String> =
                                with_prefix(&model, &p).take(n).cloned().collect();
                            prop_assert_eq!(words(Ok(got)), expected);
                        }
                    }
                }
                store.check_invariants();
            }
            for k in model.keys() {
                prop_assert_eq!(store.delete(k.as_bytes(), UNLIMITED), Ok(true));
                store.check_invariants();
            }
            prop_assert_eq!(store.node_count(), 1);
        }
    }
}
