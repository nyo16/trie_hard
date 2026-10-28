use std::collections::HashMap;

/// A trie node. Children are only reachable through the accessor methods
/// below so the child representation can change without touching the
/// traversal algorithms in [`Trie`].
pub struct TrieNode<T> {
    value: Option<T>,
    children: HashMap<char, TrieNode<T>>,
}

impl<T> TrieNode<T> {
    fn new() -> Self {
        TrieNode {
            value: None,
            children: HashMap::new(),
        }
    }

    fn child(&self, ch: char) -> Option<&Self> {
        self.children.get(&ch)
    }

    fn child_mut(&mut self, ch: char) -> Option<&mut Self> {
        self.children.get_mut(&ch)
    }

    fn child_or_insert(&mut self, ch: char) -> &mut Self {
        self.children.entry(ch).or_insert_with(TrieNode::new)
    }

    fn remove_child(&mut self, ch: char) -> Option<Self> {
        self.children.remove(&ch)
    }

    fn children_iter(&self) -> impl Iterator<Item = (char, &Self)> {
        self.children.iter().map(|(ch, node)| (*ch, node))
    }

    fn child_count(&self) -> usize {
        self.children.len()
    }

    fn take_children(&mut self) -> Vec<Self> {
        self.children.drain().map(|(_, node)| node).collect()
    }
}

impl<T> Drop for TrieNode<T> {
    /// Frees descendants iteratively so dropping a very deep chain cannot
    /// overflow the stack.
    fn drop(&mut self) {
        let mut stack = self.take_children();
        while let Some(mut node) = stack.pop() {
            stack.extend(node.take_children());
        }
    }
}

pub struct Trie<T> {
    root: TrieNode<T>,
}

impl<T> Default for Trie<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Trie<T> {
    pub fn new() -> Self {
        Trie {
            root: TrieNode::new(),
        }
    }

    fn find(&self, key: &str) -> Option<&TrieNode<T>> {
        let mut current = &self.root;
        for ch in key.chars() {
            current = current.child(ch)?;
        }
        Some(current)
    }

    pub fn insert(&mut self, key: &str, value: T) {
        let mut current = &mut self.root;
        for ch in key.chars() {
            current = current.child_or_insert(ch);
        }
        current.value = Some(value);
    }

    pub fn get(&self, key: &str) -> Option<&T> {
        self.find(key)?.value.as_ref()
    }

    /// Removes `key`, pruning nodes that only existed for it.
    /// Returns whether the key was present.
    pub fn delete(&mut self, key: &str) -> bool {
        let path: Vec<char> = key.chars().collect();

        // Pass 1: verify the key exists and find the deepest node that must
        // survive (root, holds a value, or branches). Everything below it on
        // the path exists only for `key`.
        let mut cut = 0;
        let mut current = &self.root;
        for (depth, &ch) in path.iter().enumerate() {
            if depth > 0 && (current.value.is_some() || current.child_count() > 1) {
                cut = depth;
            }
            match current.child(ch) {
                Some(next) => current = next,
                None => return false,
            }
        }
        if current.value.is_none() {
            return false;
        }
        let prune = !path.is_empty() && current.child_count() == 0;

        // Pass 2: mutate.
        let mut current = &mut self.root;
        if prune {
            for &ch in &path[..cut] {
                current = current.child_mut(ch).expect("path verified in pass 1");
            }
            current.remove_child(path[cut]);
        } else {
            for &ch in &path {
                current = current.child_mut(ch).expect("path verified in pass 1");
            }
            current.value = None;
        }
        true
    }

    /// True when at least one stored key starts with `prefix`.
    pub fn prefix_search(&self, prefix: &str) -> bool {
        self.find(prefix)
            .is_some_and(|node| node.value.is_some() || node.child_count() > 0)
    }

    pub fn auto_complete(&self, prefix: &str, max_results: usize) -> Vec<String> {
        let mut results = Vec::new();
        if max_results == 0 {
            return results;
        }
        let Some(start) = self.find(prefix) else {
            return results;
        };

        let mut buf = String::from(prefix);
        let mut stack: Vec<(&TrieNode<T>, usize, Option<char>)> = vec![(start, buf.len(), None)];
        while let Some((node, buf_len, ch)) = stack.pop() {
            buf.truncate(buf_len);
            if let Some(ch) = ch {
                buf.push(ch);
            }
            if node.value.is_some() {
                results.push(buf.clone());
                if results.len() >= max_results {
                    break;
                }
            }
            let len = buf.len();
            stack.extend(
                node.children_iter()
                    .map(|(ch, child)| (child, len, Some(ch))),
            );
        }
        results
    }

    /// Number of stored keys starting with `prefix`.
    pub fn count_prefix(&self, prefix: &str) -> usize {
        let Some(start) = self.find(prefix) else {
            return 0;
        };
        let mut count = 0;
        let mut stack = vec![start];
        while let Some(node) = stack.pop() {
            if node.value.is_some() {
                count += 1;
            }
            stack.extend(node.children_iter().map(|(_, child)| child));
        }
        count
    }

    pub fn add_word_list<F>(&mut self, words: &[&str], value_mapper: F)
    where
        F: Fn(&str) -> T,
    {
        for word in words {
            self.insert(word, value_mapper(word));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::collections::{BTreeMap, BTreeSet};
    use std::ops::Bound;

    impl<T> Trie<T> {
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

    const KEYS: [&str; 6] = ["car", "café", "🦀", "e\u{301}", "", "naïve"];

    #[test]
    fn insert_get_delete_roundtrip() {
        let mut trie = Trie::new();
        for (i, key) in KEYS.iter().enumerate() {
            trie.insert(key, i);
        }
        for (i, key) in KEYS.iter().enumerate() {
            assert_eq!(trie.get(key), Some(&i), "get {key:?}");
        }
        for key in KEYS {
            assert!(trie.delete(key), "delete {key:?}");
            assert_eq!(trie.get(key), None);
            assert!(!trie.delete(key), "second delete {key:?}");
        }
        assert_eq!(trie.node_count(), 1);
        trie.insert("café", 7);
        assert_eq!(trie.get("café"), Some(&7));
    }

    #[test]
    fn delete_missing_or_valueless_key() {
        let mut trie = Trie::new();
        trie.insert("card", 1);
        assert!(!trie.delete("car"));
        assert!(!trie.delete("cards"));
        assert!(!trie.delete("x"));
        assert!(!trie.delete(""));
        assert_eq!(trie.get("card"), Some(&1));
        assert_eq!(trie.node_count(), 5);
    }

    #[test]
    fn delete_prunes_shared_prefixes() {
        let mut trie = Trie::new();
        trie.insert("car", 1);
        trie.insert("card", 2);
        assert!(trie.delete("card"));
        assert_eq!(trie.get("car"), Some(&1));
        assert_eq!(trie.node_count(), 4);

        let mut trie = Trie::new();
        trie.insert("car", 1);
        trie.insert("card", 2);
        assert!(trie.delete("car"));
        assert_eq!(trie.get("card"), Some(&2));
        assert_eq!(trie.node_count(), 5);

        let mut trie = Trie::new();
        trie.insert("cart", 1);
        trie.insert("card", 2);
        assert!(trie.delete("card"));
        assert_eq!(trie.get("cart"), Some(&1));
        assert_eq!(trie.node_count(), 5);
    }

    #[test]
    fn very_deep_keys_do_not_overflow() {
        let key = "a".repeat(100_000);
        let mut trie = Trie::new();
        trie.insert(&key, 1);
        assert_eq!(trie.auto_complete("", 1), vec![key.clone()]);
        assert_eq!(trie.count_prefix("a"), 1);
        assert!(trie.delete(&key));
        assert_eq!(trie.node_count(), 1);

        trie.insert(&key, 2);
        drop(trie);
    }

    #[test]
    fn count_prefix_is_not_capped() {
        let mut trie = Trie::new();
        for i in 0..1000 {
            trie.insert(&format!("w{i}"), ());
        }
        assert_eq!(trie.count_prefix(""), 1000);
        assert_eq!(trie.count_prefix("w"), 1000);
        assert_eq!(trie.count_prefix("w1"), 111);
        assert_eq!(trie.count_prefix("x"), 0);
    }

    #[test]
    fn prefix_search_requires_a_stored_key() {
        let mut trie: Trie<()> = Trie::new();
        assert!(!trie.prefix_search(""));
        trie.insert("ab", ());
        assert!(trie.prefix_search(""));
        assert!(trie.prefix_search("a"));
        assert!(trie.prefix_search("ab"));
        assert!(!trie.prefix_search("abc"));
        trie.delete("ab");
        assert!(!trie.prefix_search(""));
    }

    #[test]
    fn auto_complete_respects_limit() {
        let mut trie = Trie::new();
        for key in ["car", "card", "care", "cat", "dog"] {
            trie.insert(key, ());
        }
        assert!(trie.auto_complete("ca", 0).is_empty());
        assert_eq!(trie.auto_complete("ca", 2).len(), 2);
        let all: BTreeSet<_> = trie.auto_complete("ca", 10).into_iter().collect();
        assert_eq!(
            all,
            BTreeSet::from(["car", "card", "care", "cat"].map(String::from))
        );
        assert!(trie.auto_complete("x", 10).is_empty());
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
            let mut trie = Trie::new();
            let mut model = BTreeMap::new();
            for op in ops {
                match op {
                    Op::Insert(k, v) => {
                        trie.insert(&k, v);
                        model.insert(k, v);
                    }
                    Op::Delete(k) => prop_assert_eq!(trie.delete(&k), model.remove(&k).is_some()),
                    Op::Get(k) => prop_assert_eq!(trie.get(&k), model.get(&k)),
                    Op::Count(p) => {
                        let expected = with_prefix(&model, &p).count();
                        prop_assert_eq!(trie.count_prefix(&p), expected);
                        prop_assert_eq!(trie.prefix_search(&p), expected > 0);
                    }
                    Op::Complete(p, n) => {
                        let got = trie.auto_complete(&p, n);
                        let expected: BTreeSet<&String> = with_prefix(&model, &p).collect();
                        prop_assert_eq!(got.len(), n.min(expected.len()));
                        let unique: BTreeSet<&String> = got.iter().collect();
                        prop_assert_eq!(unique.len(), got.len());
                        prop_assert!(unique.is_subset(&expected));
                    }
                }
            }
            for k in model.keys().cloned().collect::<Vec<_>>() {
                prop_assert!(trie.delete(&k));
            }
            prop_assert_eq!(trie.node_count(), 1);
        }
    }
}
