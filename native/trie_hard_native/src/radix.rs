//! Path-compressed (radix) trie: edges carry byte strings, so chains of
//! single-child nodes collapse into one node.

use crate::store::OverBudget;

struct Node<T> {
    /// Bytes on the edge from the parent; empty only for the root.
    label: Box<[u8]>,
    value: Option<T>,
    /// Sorted by `label[0]`; siblings never share a first byte.
    children: Vec<Node<T>>,
}

impl<T> Node<T> {
    fn new(label: &[u8], value: Option<T>) -> Self {
        Node {
            label: label.into(),
            value,
            children: Vec::new(),
        }
    }

    fn child_index(&self, byte: u8) -> Result<usize, usize> {
        self.children
            .binary_search_by_key(&byte, |child| child.label[0])
    }

    fn add_child(&mut self, i: usize, child: Self) {
        // Most nodes have few children; avoid the default minimum capacity of 4.
        if self.children.len() < 4 {
            self.children.reserve_exact(1);
        }
        self.children.insert(i, child);
    }

    fn take_children(&mut self) -> Vec<Self> {
        std::mem::take(&mut self.children)
    }

    /// Splits the edge to child `i` after `at` bytes: the child keeps the
    /// first `at` bytes and gains one child holding the rest of the old edge.
    fn split_child(&mut self, i: usize, at: usize) {
        let child = &mut self.children[i];
        let lower = Node {
            label: child.label[at..].into(),
            value: child.value.take(),
            children: child.take_children(),
        };
        child.label = child.label[..at].into();
        child.children = vec![lower];
    }

    /// Absorbs the only child: its edge is appended to ours.
    fn merge_only_child(&mut self) {
        debug_assert!(self.value.is_none() && self.children.len() == 1);
        let mut child = self.children.pop().expect("exactly one child");
        let mut label = Vec::with_capacity(self.label.len() + child.label.len());
        label.extend_from_slice(&self.label);
        label.extend_from_slice(&child.label);
        self.label = label.into();
        self.value = child.value.take();
        self.children = child.take_children();
    }
}

impl<T> Drop for Node<T> {
    /// Frees descendants iteratively so dropping a very deep trie cannot
    /// overflow the stack.
    fn drop(&mut self) {
        let mut stack = self.take_children();
        while let Some(mut node) = stack.pop() {
            stack.extend(node.take_children());
        }
    }
}

fn common_prefix_len(a: &[u8], b: &[u8]) -> usize {
    a.iter().zip(b).take_while(|(x, y)| x == y).count()
}

pub struct RadixTrie<T> {
    root: Node<T>,
}

impl<T> Default for RadixTrie<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> RadixTrie<T> {
    pub fn new() -> Self {
        RadixTrie {
            root: Node::new(b"", None),
        }
    }

    pub fn insert(&mut self, key: &[u8], value: T) {
        let mut node = &mut self.root;
        let mut rest = key;
        loop {
            if rest.is_empty() {
                node.value = Some(value);
                return;
            }
            match node.child_index(rest[0]) {
                Err(i) => {
                    node.add_child(i, Node::new(rest, Some(value)));
                    return;
                }
                Ok(i) => {
                    let common = common_prefix_len(&node.children[i].label, rest);
                    if common < node.children[i].label.len() {
                        node.split_child(i, common);
                    }
                    node = &mut node.children[i];
                    rest = &rest[common..];
                }
            }
        }
    }

    pub fn get(&self, key: &[u8]) -> Option<&T> {
        let mut node = &self.root;
        let mut rest = key;
        while !rest.is_empty() {
            let child = &node.children[node.child_index(rest[0]).ok()?];
            rest = rest.strip_prefix(&*child.label)?;
            node = child;
        }
        node.value.as_ref()
    }

    /// The node whose subtree holds exactly the keys starting with `prefix`,
    /// plus the part of its edge that extends past `prefix` (non-empty when
    /// the prefix ends mid-edge).
    fn locate(&self, prefix: &[u8]) -> Option<(&Node<T>, &[u8])> {
        let mut node = &self.root;
        let mut rest = prefix;
        loop {
            if rest.is_empty() {
                return Some((node, &[]));
            }
            let child = &node.children[node.child_index(rest[0]).ok()?];
            match rest.strip_prefix(&*child.label) {
                Some(after) => {
                    rest = after;
                    node = child;
                }
                None => {
                    return child.label.strip_prefix(rest).map(|tail| (child, tail));
                }
            }
        }
    }

    /// Removes `key`, pruning a leaf it leaves valueless and merging nodes
    /// left with a single child and no value. Returns whether it was present.
    pub fn delete(&mut self, key: &[u8]) -> bool {
        // Pass 1: child indices along the path; verify the key exists.
        let mut path = Vec::new();
        let mut node = &self.root;
        let mut rest = key;
        while !rest.is_empty() {
            let Ok(i) = node.child_index(rest[0]) else {
                return false;
            };
            let child = &node.children[i];
            let Some(after) = rest.strip_prefix(&*child.label) else {
                return false;
            };
            path.push(i);
            rest = after;
            node = child;
        }
        if node.value.is_none() {
            return false;
        }

        // Pass 2: mutate.
        let Some((&last, parents)) = path.split_last() else {
            self.root.value = None;
            return true;
        };
        let mut parent = &mut self.root;
        for &i in parents {
            parent = &mut parent.children[i];
        }
        let parent_is_root = parents.is_empty();
        let target = &mut parent.children[last];
        target.value = None;
        match target.children.len() {
            0 => {
                parent.children.remove(last);
                if !parent_is_root && parent.value.is_none() && parent.children.len() == 1 {
                    parent.merge_only_child();
                }
            }
            1 => target.merge_only_child(),
            _ => {}
        }
        true
    }

    /// True when at least one stored key starts with `prefix`.
    pub fn has_prefix(&self, prefix: &[u8]) -> bool {
        self.locate(prefix)
            .is_some_and(|(node, _)| node.value.is_some() || !node.children.is_empty())
    }

    /// Up to `max_results` stored keys starting with `prefix`, in ascending
    /// byte order. Visits at most `budget` nodes, else `Err(OverBudget)`.
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
        let Some((start, tail)) = self.locate(prefix) else {
            return Ok(results);
        };

        let mut buf = prefix.to_vec();
        let mut stack: Vec<(&Node<T>, usize, &[u8])> = vec![(start, buf.len(), tail)];
        while let Some((node, buf_len, label)) = stack.pop() {
            budget = budget.checked_sub(1).ok_or(OverBudget)?;
            buf.truncate(buf_len);
            buf.extend_from_slice(label);
            if node.value.is_some() {
                results.push(buf.clone());
                if results.len() >= max_results {
                    break;
                }
            }
            // Reverse push so the smallest first byte is visited first.
            let len = buf.len();
            stack.extend(
                node.children
                    .iter()
                    .rev()
                    .map(|child| (child, len, &*child.label)),
            );
        }
        Ok(results)
    }

    /// Number of stored keys starting with `prefix`.
    /// Visits at most `budget` nodes, else `Err(OverBudget)`.
    pub fn count(&self, prefix: &[u8], mut budget: usize) -> Result<usize, OverBudget> {
        let Some((start, _)) = self.locate(prefix) else {
            return Ok(0);
        };
        let mut count = 0;
        let mut stack = vec![start];
        while let Some(node) = stack.pop() {
            budget = budget.checked_sub(1).ok_or(OverBudget)?;
            if node.value.is_some() {
                count += 1;
            }
            stack.extend(node.children.iter());
        }
        Ok(count)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    const UNLIMITED: usize = usize::MAX;

    impl<T> RadixTrie<T> {
        pub(crate) fn node_count(&self) -> usize {
            let mut count = 0;
            let mut stack = vec![&self.root];
            while let Some(node) = stack.pop() {
                count += 1;
                stack.extend(node.children.iter());
            }
            count
        }

        /// Structural invariants: non-root edges are non-empty, siblings are
        /// sorted with distinct first bytes, and every non-root node either
        /// holds a value or branches (no prunable or mergeable node remains).
        pub(crate) fn check_invariants(&self) {
            let mut stack: Vec<(&Node<T>, bool)> = vec![(&self.root, true)];
            while let Some((node, is_root)) = stack.pop() {
                if is_root {
                    assert!(node.label.is_empty());
                } else {
                    assert!(!node.label.is_empty(), "empty edge");
                    assert!(
                        node.value.is_some() || node.children.len() >= 2,
                        "valueless node with {} children",
                        node.children.len()
                    );
                }
                assert!(node
                    .children
                    .windows(2)
                    .all(|w| w[0].label[0] < w[1].label[0]));
                stack.extend(node.children.iter().map(|child| (child, false)));
            }
        }

        fn labels(&self) -> Vec<&[u8]> {
            let mut labels = Vec::new();
            let mut stack = vec![&self.root];
            while let Some(node) = stack.pop() {
                labels.push(&*node.label);
                stack.extend(node.children.iter().rev());
            }
            labels
        }
    }

    fn words(results: Result<Vec<Vec<u8>>, OverBudget>) -> Vec<String> {
        results
            .unwrap()
            .into_iter()
            .map(|w| String::from_utf8(w).unwrap())
            .collect()
    }

    #[test]
    fn insert_splits_edges_at_the_common_prefix() {
        let mut trie = RadixTrie::new();
        trie.insert(b"card", 1);
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
        trie.insert(b"car", 2);
        assert_eq!(trie.labels(), [&b""[..], b"car", b"d"]);
        trie.insert(b"care", 3);
        assert_eq!(trie.labels(), [&b""[..], b"car", b"d", b"e"]);
        trie.insert(b"cat", 4);
        assert_eq!(trie.labels(), [&b""[..], b"ca", b"r", b"d", b"e", b"t"]);
        trie.check_invariants();
        for (key, v) in [("card", 1), ("car", 2), ("care", 3), ("cat", 4)] {
            assert_eq!(trie.get(key.as_bytes()), Some(&v));
        }
        assert_eq!(trie.get(b"ca"), None);
        assert_eq!(trie.get(b"c"), None);
        assert_eq!(trie.get(b"cards"), None);
    }

    #[test]
    fn delete_merges_single_child_nodes() {
        let mut trie = RadixTrie::new();
        for key in ["card", "car", "care"] {
            trie.insert(key.as_bytes(), ());
        }
        // "car" has two children: only its value goes.
        assert!(trie.delete(b"car"));
        assert_eq!(trie.labels(), [&b""[..], b"car", b"d", b"e"]);
        // Removing leaf "care" leaves valueless "car" with one child: merge.
        assert!(trie.delete(b"care"));
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
        trie.check_invariants();

        let mut trie = RadixTrie::new();
        trie.insert(b"car", ());
        trie.insert(b"card", ());
        // Valueless "car" with one child merges with it.
        assert!(trie.delete(b"car"));
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
        assert!(trie.delete(b"card"));
        assert_eq!(trie.node_count(), 1);
    }

    #[test]
    fn delete_of_missing_keys_including_mid_edge() {
        let mut trie = RadixTrie::new();
        trie.insert(b"card", 1);
        assert!(!trie.delete(b"car"));
        assert!(!trie.delete(b"ca"));
        assert!(!trie.delete(b"cards"));
        assert!(!trie.delete(b"cart"));
        assert!(!trie.delete(b""));
        assert_eq!(trie.get(b"card"), Some(&1));
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
    }

    #[test]
    fn prefix_queries_may_end_mid_edge() {
        let mut trie = RadixTrie::new();
        trie.insert(b"card", ());
        trie.insert(b"cards", ());
        assert!(trie.has_prefix(b"ca"));
        assert!(!trie.has_prefix(b"cb"));
        assert!(!trie.has_prefix(b"cardz"));
        assert_eq!(
            words(trie.complete(b"ca", 10, UNLIMITED)),
            ["card", "cards"]
        );
        assert_eq!(words(trie.complete(b"cards", 10, UNLIMITED)), ["cards"]);
        assert_eq!(trie.count(b"c", UNLIMITED), Ok(2));
        assert_eq!(trie.count(b"cax", UNLIMITED), Ok(0));
    }

    #[test]
    fn complete_is_lexicographic() {
        let mut trie = RadixTrie::new();
        for key in ["cat", "dog", "care", "card", "car", "café", ""] {
            trie.insert(key.as_bytes(), ());
        }
        assert_eq!(
            words(trie.complete(b"", 10, UNLIMITED)),
            ["", "café", "car", "card", "care", "cat", "dog"]
        );
        assert_eq!(words(trie.complete(b"car", 2, UNLIMITED)), ["car", "card"]);
        assert_eq!(trie.complete(b"ca", 0, UNLIMITED), Ok(vec![]));
    }

    #[test]
    fn traversals_stop_at_budget() {
        let mut trie = RadixTrie::new();
        for key in ["a", "ab", "abc"] {
            trie.insert(key.as_bytes(), ());
        }
        // Nodes: root, a, b, c.
        assert_eq!(trie.count(b"", 4), Ok(3));
        assert_eq!(trie.count(b"", 3), Err(OverBudget));
        assert_eq!(trie.complete(b"", 10, 3), Err(OverBudget));
        assert_eq!(words(trie.complete(b"", 1, 2)), ["a"]);
    }

    #[test]
    fn deep_chains_do_not_overflow() {
        let mut trie = RadixTrie::new();
        // A chain of 5k nested nodes; building it is quadratic (each insert
        // walks the chain), so it is kept small for debug-mode test runs.
        let key = "a".repeat(5_000);
        for len in 1..=key.len() {
            trie.insert(&key.as_bytes()[..len], ());
        }
        assert_eq!(trie.count(b"", UNLIMITED), Ok(5_000));
        assert_eq!(words(trie.complete(b"aaa", 1, UNLIMITED)), ["aaa"]);
        drop(trie);
    }
}
