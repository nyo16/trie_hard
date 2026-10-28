//! Byte-keyed trie with sorted child arrays (one node per key byte).

/// A traversal exceeded its node-visit budget; retry with a larger one.
#[derive(Debug, PartialEq, Eq)]
pub struct OverBudget;

/// A trie node. Children are only reachable through the accessor methods
/// below so the child representation can change without touching the
/// traversal algorithms in [`SortedTrie`].
struct Node<T> {
    value: Option<T>,
    /// Edge bytes, sorted; `children[i]` is reached via `keys[i]`.
    keys: Vec<u8>,
    children: Vec<Node<T>>,
}

impl<T> Node<T> {
    const fn new() -> Self {
        Node {
            value: None,
            keys: Vec::new(),
            children: Vec::new(),
        }
    }

    fn child(&self, byte: u8) -> Option<&Self> {
        let i = self.keys.binary_search(&byte).ok()?;
        Some(&self.children[i])
    }

    fn child_mut(&mut self, byte: u8) -> Option<&mut Self> {
        let i = self.keys.binary_search(&byte).ok()?;
        Some(&mut self.children[i])
    }

    fn child_or_insert(&mut self, byte: u8) -> &mut Self {
        let i = match self.keys.binary_search(&byte) {
            Ok(i) => i,
            Err(i) => {
                // Most nodes have one or two children; the default amortized
                // growth (min capacity 4) would triple their size. Wide nodes
                // fall back to amortized growth.
                if self.children.len() < 4 {
                    self.keys.reserve_exact(1);
                    self.children.reserve_exact(1);
                }
                self.keys.insert(i, byte);
                self.children.insert(i, Node::new());
                i
            }
        };
        &mut self.children[i]
    }

    fn remove_child(&mut self, byte: u8) -> Option<Self> {
        let i = self.keys.binary_search(&byte).ok()?;
        self.keys.remove(i);
        Some(self.children.remove(i))
    }

    /// Children in ascending byte order.
    fn children_iter(&self) -> impl DoubleEndedIterator<Item = (u8, &Self)> {
        self.keys.iter().copied().zip(self.children.iter())
    }

    fn child_count(&self) -> usize {
        self.children.len()
    }

    fn take_children(&mut self) -> Vec<Self> {
        self.keys = Vec::new();
        std::mem::take(&mut self.children)
    }
}

impl<T> Drop for Node<T> {
    /// Frees descendants iteratively so dropping a very deep chain cannot
    /// overflow the stack.
    fn drop(&mut self) {
        let mut stack = self.take_children();
        while let Some(mut node) = stack.pop() {
            stack.extend(node.take_children());
        }
    }
}

pub struct SortedTrie<T> {
    root: Node<T>,
}

impl<T> Default for SortedTrie<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> SortedTrie<T> {
    pub const fn new() -> Self {
        SortedTrie { root: Node::new() }
    }

    fn find(&self, key: &[u8]) -> Option<&Node<T>> {
        let mut current = &self.root;
        for &byte in key {
            current = current.child(byte)?;
        }
        Some(current)
    }

    pub fn insert(&mut self, key: &[u8], value: T) {
        let mut current = &mut self.root;
        for &byte in key {
            current = current.child_or_insert(byte);
        }
        current.value = Some(value);
    }

    pub fn get(&self, key: &[u8]) -> Option<&T> {
        self.find(key)?.value.as_ref()
    }

    /// Removes `key`, pruning nodes that only existed for it.
    /// Returns whether the key was present.
    pub fn delete(&mut self, key: &[u8]) -> bool {
        // Pass 1: verify the key exists and find the deepest node that must
        // survive (root, holds a value, or branches). Everything below it on
        // the path exists only for `key`.
        let mut cut = 0;
        let mut current = &self.root;
        for (depth, &byte) in key.iter().enumerate() {
            if depth > 0 && (current.value.is_some() || current.child_count() > 1) {
                cut = depth;
            }
            match current.child(byte) {
                Some(next) => current = next,
                None => return false,
            }
        }
        if current.value.is_none() {
            return false;
        }
        let prune = !key.is_empty() && current.child_count() == 0;

        // Pass 2: mutate.
        let mut current = &mut self.root;
        if prune {
            for &byte in &key[..cut] {
                current = current.child_mut(byte).expect("path verified in pass 1");
            }
            current.remove_child(key[cut]);
        } else {
            for &byte in key {
                current = current.child_mut(byte).expect("path verified in pass 1");
            }
            current.value = None;
        }
        true
    }

    /// True when at least one stored key starts with `prefix`.
    pub fn has_prefix(&self, prefix: &[u8]) -> bool {
        self.find(prefix)
            .is_some_and(|node| node.value.is_some() || node.child_count() > 0)
    }

    /// Up to `max_results` stored keys starting with `prefix`, in ascending
    /// byte order (= codepoint order for UTF-8 keys).
    /// Visits at most `budget` nodes below the prefix, else `Err(OverBudget)`.
    pub fn complete(
        &self,
        prefix: &[u8],
        max_results: usize,
        mut budget: usize,
    ) -> Result<Vec<Vec<u8>>, OverBudget> {
        let mut results = Vec::new();
        if max_results == 0 {
            return Ok(results);
        }
        let Some(start) = self.find(prefix) else {
            return Ok(results);
        };

        let mut buf = prefix.to_vec();
        let mut stack: Vec<(&Node<T>, usize, Option<u8>)> = vec![(start, buf.len(), None)];
        while let Some((node, buf_len, byte)) = stack.pop() {
            budget = budget.checked_sub(1).ok_or(OverBudget)?;
            buf.truncate(buf_len);
            buf.extend(byte);
            if node.value.is_some() {
                results.push(buf.clone());
                if results.len() >= max_results {
                    break;
                }
            }
            // Reverse push so the smallest byte is popped (visited) first.
            let len = buf.len();
            stack.extend(
                node.children_iter()
                    .rev()
                    .map(|(byte, child)| (child, len, Some(byte))),
            );
        }
        Ok(results)
    }

    /// Number of stored keys starting with `prefix`.
    /// Visits at most `budget` nodes below the prefix, else `Err(OverBudget)`.
    pub fn count(&self, prefix: &[u8], mut budget: usize) -> Result<usize, OverBudget> {
        let Some(start) = self.find(prefix) else {
            return Ok(0);
        };
        let mut count = 0;
        let mut stack = vec![start];
        while let Some(node) = stack.pop() {
            budget = budget.checked_sub(1).ok_or(OverBudget)?;
            if node.value.is_some() {
                count += 1;
            }
            stack.extend(node.children_iter().map(|(_, child)| child));
        }
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::collections::BTreeMap;
    use std::ops::Bound;

    const UNLIMITED: usize = usize::MAX;

    impl<T> SortedTrie<T> {
        fn node_count(&self) -> usize {
            let mut count = 0;
            let mut stack = vec![&self.root];
            while let Some(node) = stack.pop() {
                count += 1;
                stack.extend(node.children_iter().map(|(_, child)| child));
            }
            count
        }
    }

    fn words(results: Result<Vec<Vec<u8>>, OverBudget>) -> Vec<String> {
        results
            .unwrap()
            .into_iter()
            .map(|w| String::from_utf8(w).unwrap())
            .collect()
    }

    const KEYS: [&str; 6] = ["car", "café", "🦀", "e\u{301}", "", "naïve"];

    #[test]
    fn insert_get_delete_roundtrip() {
        let mut trie = SortedTrie::new();
        for (i, key) in KEYS.iter().enumerate() {
            trie.insert(key.as_bytes(), i);
        }
        for (i, key) in KEYS.iter().enumerate() {
            assert_eq!(trie.get(key.as_bytes()), Some(&i), "get {key:?}");
        }
        for key in KEYS {
            assert!(trie.delete(key.as_bytes()), "delete {key:?}");
            assert_eq!(trie.get(key.as_bytes()), None);
            assert!(!trie.delete(key.as_bytes()), "second delete {key:?}");
        }
        assert_eq!(trie.node_count(), 1);
        trie.insert("café".as_bytes(), 7);
        assert_eq!(trie.get("café".as_bytes()), Some(&7));
    }

    #[test]
    fn delete_missing_or_valueless_key() {
        let mut trie = SortedTrie::new();
        trie.insert(b"card", 1);
        assert!(!trie.delete(b"car"));
        assert!(!trie.delete(b"cards"));
        assert!(!trie.delete(b"x"));
        assert!(!trie.delete(b""));
        assert_eq!(trie.get(b"card"), Some(&1));
        assert_eq!(trie.node_count(), 5);
    }

    #[test]
    fn delete_prunes_shared_prefixes() {
        let mut trie = SortedTrie::new();
        trie.insert(b"car", 1);
        trie.insert(b"card", 2);
        assert!(trie.delete(b"card"));
        assert_eq!(trie.get(b"car"), Some(&1));
        assert_eq!(trie.node_count(), 4);

        let mut trie = SortedTrie::new();
        trie.insert(b"car", 1);
        trie.insert(b"card", 2);
        assert!(trie.delete(b"car"));
        assert_eq!(trie.get(b"card"), Some(&2));
        assert_eq!(trie.node_count(), 5);

        let mut trie = SortedTrie::new();
        trie.insert(b"cart", 1);
        trie.insert(b"card", 2);
        assert!(trie.delete(b"card"));
        assert_eq!(trie.get(b"cart"), Some(&1));
        assert_eq!(trie.node_count(), 5);
    }

    #[test]
    fn very_deep_keys_do_not_overflow() {
        let key = "a".repeat(100_000);
        let mut trie = SortedTrie::new();
        trie.insert(key.as_bytes(), 1);
        assert_eq!(words(trie.complete(b"", 1, UNLIMITED)), vec![key.clone()]);
        assert_eq!(trie.count(b"a", UNLIMITED), Ok(1));
        assert!(trie.delete(key.as_bytes()));
        assert_eq!(trie.node_count(), 1);

        trie.insert(key.as_bytes(), 2);
        drop(trie);
    }

    #[test]
    fn count_is_not_capped() {
        let mut trie = SortedTrie::new();
        for i in 0..1000 {
            trie.insert(format!("w{i}").as_bytes(), ());
        }
        assert_eq!(trie.count(b"", UNLIMITED), Ok(1000));
        assert_eq!(trie.count(b"w", UNLIMITED), Ok(1000));
        assert_eq!(trie.count(b"w1", UNLIMITED), Ok(111));
        assert_eq!(trie.count(b"x", UNLIMITED), Ok(0));
    }

    #[test]
    fn traversals_stop_at_budget() {
        let mut trie = SortedTrie::new();
        for key in ["a", "ab", "abc"] {
            trie.insert(key.as_bytes(), ());
        }
        // Nodes under "": root, a, ab, abc.
        assert_eq!(trie.count(b"", 4), Ok(3));
        assert_eq!(trie.count(b"", 3), Err(OverBudget));
        assert_eq!(trie.complete(b"", 10, 3), Err(OverBudget));
        assert_eq!(words(trie.complete(b"", 1, 2)), vec!["a"]);
        assert_eq!(trie.count(b"x", 0), Ok(0));
    }

    #[test]
    fn has_prefix_requires_a_stored_key() {
        let mut trie: SortedTrie<()> = SortedTrie::new();
        assert!(!trie.has_prefix(b""));
        trie.insert(b"ab", ());
        assert!(trie.has_prefix(b""));
        assert!(trie.has_prefix(b"a"));
        assert!(trie.has_prefix(b"ab"));
        assert!(!trie.has_prefix(b"abc"));
        trie.delete(b"ab");
        assert!(!trie.has_prefix(b""));
    }

    #[test]
    fn complete_is_lexicographic_and_truncates_in_order() {
        let mut trie = SortedTrie::new();
        for key in ["cat", "dog", "care", "card", "car", "café"] {
            trie.insert(key.as_bytes(), ());
        }
        assert_eq!(trie.complete(b"ca", 0, UNLIMITED), Ok(vec![]));
        assert_eq!(words(trie.complete(b"car", 2, UNLIMITED)), ["car", "card"]);
        // "caf" < "car" bytewise; "é" sorts after every ASCII letter.
        assert_eq!(
            words(trie.complete(b"ca", 10, UNLIMITED)),
            ["café", "car", "card", "care", "cat"]
        );
        assert_eq!(words(trie.complete(b"caf", 10, UNLIMITED)), ["café"]);
        assert_eq!(trie.complete(b"x", 10, UNLIMITED), Ok(vec![]));
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

    fn with_prefix<'a>(
        model: &'a BTreeMap<String, u32>,
        prefix: &'a str,
    ) -> impl Iterator<Item = &'a String> {
        model
            .range::<str, _>((Bound::Included(prefix), Bound::Unbounded))
            .map(|(k, _)| k)
            .take_while(move |k| k.starts_with(prefix))
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(512))]

        #[test]
        fn matches_btreemap_model(ops in prop::collection::vec(op(), 0..64)) {
            let mut trie = SortedTrie::new();
            let mut model = BTreeMap::new();
            for op in ops {
                match op {
                    Op::Insert(k, v) => {
                        trie.insert(k.as_bytes(), v);
                        model.insert(k, v);
                    }
                    Op::Delete(k) => {
                        prop_assert_eq!(trie.delete(k.as_bytes()), model.remove(&k).is_some());
                    }
                    Op::Get(k) => prop_assert_eq!(trie.get(k.as_bytes()), model.get(&k)),
                    Op::Count(p) => {
                        let expected = with_prefix(&model, &p).count();
                        prop_assert_eq!(trie.count(p.as_bytes(), UNLIMITED), Ok(expected));
                        prop_assert_eq!(trie.has_prefix(p.as_bytes()), expected > 0);
                    }
                    Op::Complete(p, n) => {
                        // BTreeMap<String> order is byte order, so results must match exactly.
                        let expected: Vec<String> =
                            with_prefix(&model, &p).take(n).cloned().collect();
                        prop_assert_eq!(words(trie.complete(p.as_bytes(), n, UNLIMITED)), expected);
                    }
                }
            }
            for k in model.keys() {
                prop_assert!(trie.delete(k.as_bytes()));
            }
            prop_assert_eq!(trie.node_count(), 1);
        }
    }
}
