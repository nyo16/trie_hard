//! Path-compressed (radix) trie: edges carry byte strings, so chains of
//! single-child nodes collapse into one node.

use crate::store::{Budget, OverBudget};

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

    /// Splitting an existing edge copies it, which is charged to `budget` as
    /// bytes before anything is changed; `Err(OverBudget)` leaves the trie as
    /// it was.
    pub fn insert(&mut self, key: &[u8], value: T, mut budget: Budget) -> Result<(), OverBudget> {
        let mut node = &mut self.root;
        let mut rest = key;
        loop {
            if rest.is_empty() {
                node.value = Some(value);
                return Ok(());
            }
            match node.child_index(rest[0]) {
                Err(i) => {
                    node.add_child(i, Node::new(rest, Some(value)));
                    return Ok(());
                }
                Ok(i) => {
                    let label_len = node.children[i].label.len();
                    let common = common_prefix_len(&node.children[i].label, rest);
                    if common < label_len {
                        // At most one split per insert, and nothing has been
                        // mutated yet.
                        budget.copy(label_len)?;
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
    /// A merge copies both edges, which is charged to `budget` as bytes before
    /// anything is changed; `Err(OverBudget)` leaves the trie as it was.
    pub fn delete(&mut self, key: &[u8], mut budget: Budget) -> Result<bool, OverBudget> {
        // Pass 1: child indices along the path; verify the key exists.
        let mut path = Vec::new();
        let mut parent = &self.root;
        let mut node = &self.root;
        let mut rest = key;
        while !rest.is_empty() {
            let Ok(i) = node.child_index(rest[0]) else {
                return Ok(false);
            };
            let child = &node.children[i];
            let Some(after) = rest.strip_prefix(&*child.label) else {
                return Ok(false);
            };
            path.push(i);
            rest = after;
            parent = node;
            node = child;
        }
        if node.value.is_none() {
            return Ok(false);
        }
        // Bytes a merge in pass 2 will copy.
        let merge_bytes = match (node.children.len(), path.as_slice()) {
            (1, [_, ..]) => node.label.len() + node.children[0].label.len(),
            (0, [.., _, last]) if parent.value.is_none() && parent.children.len() == 2 => {
                parent.label.len() + parent.children[1 - last].label.len()
            }
            _ => 0,
        };
        budget.copy(merge_bytes)?;

        // Pass 2: mutate.
        let Some((&last, parents)) = path.split_last() else {
            self.root.value = None;
            return Ok(true);
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
        Ok(true)
    }

    /// True when at least one stored key starts with `prefix`.
    pub fn has_prefix(&self, prefix: &[u8]) -> bool {
        self.locate(prefix)
            .is_some_and(|(node, _)| node.value.is_some() || !node.children.is_empty())
    }

    /// Up to `max_results` stored keys starting with `prefix`, in ascending
    /// byte order. Charges one node visit per node and every byte copied into
    /// the key buffer and results against `budget`, else `Err(OverBudget)`.
    pub fn complete(
        &self,
        prefix: &[u8],
        max_results: usize,
        mut budget: Budget,
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
            budget.visit(label.len())?;
            buf.truncate(buf_len);
            buf.extend_from_slice(label);
            if node.value.is_some() {
                budget.copy(buf.len())?;
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
    /// Charges one node visit per node, else `Err(OverBudget)`.
    pub fn count(&self, prefix: &[u8], mut budget: Budget) -> Result<usize, OverBudget> {
        let Some((start, _)) = self.locate(prefix) else {
            return Ok(0);
        };
        let mut count = 0;
        let mut stack = vec![start];
        while let Some(node) = stack.pop() {
            budget.visit(0)?;
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

    const UNLIMITED: Budget = Budget::UNLIMITED;
    const fn nodes(n: usize) -> Budget {
        Budget::new(n, usize::MAX)
    }
    const fn bytes(n: usize) -> Budget {
        Budget::new(usize::MAX, n)
    }

    impl<T> RadixTrie<T> {
        fn put(&mut self, key: &[u8], value: T) {
            self.insert(key, value, UNLIMITED).unwrap();
        }

        fn del(&mut self, key: &[u8]) -> bool {
            self.delete(key, UNLIMITED).unwrap()
        }

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
        trie.put(b"card", 1);
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
        trie.put(b"car", 2);
        assert_eq!(trie.labels(), [&b""[..], b"car", b"d"]);
        trie.put(b"care", 3);
        assert_eq!(trie.labels(), [&b""[..], b"car", b"d", b"e"]);
        trie.put(b"cat", 4);
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
            trie.put(key.as_bytes(), ());
        }
        // "car" has two children: only its value goes.
        assert!(trie.del(b"car"));
        assert_eq!(trie.labels(), [&b""[..], b"car", b"d", b"e"]);
        // Removing leaf "care" leaves valueless "car" with one child: merge.
        assert!(trie.del(b"care"));
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
        trie.check_invariants();

        let mut trie = RadixTrie::new();
        trie.put(b"car", ());
        trie.put(b"card", ());
        // Valueless "car" with one child merges with it.
        assert!(trie.del(b"car"));
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
        assert!(trie.del(b"card"));
        assert_eq!(trie.node_count(), 1);
    }

    #[test]
    fn delete_of_missing_keys_including_mid_edge() {
        let mut trie = RadixTrie::new();
        trie.put(b"card", 1);
        assert!(!trie.del(b"car"));
        assert!(!trie.del(b"ca"));
        assert!(!trie.del(b"cards"));
        assert!(!trie.del(b"cart"));
        assert!(!trie.del(b""));
        assert_eq!(trie.get(b"card"), Some(&1));
        assert_eq!(trie.labels(), [&b""[..], b"card"]);
    }

    #[test]
    fn prefix_queries_may_end_mid_edge() {
        let mut trie = RadixTrie::new();
        trie.put(b"card", ());
        trie.put(b"cards", ());
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
            trie.put(key.as_bytes(), ());
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
            trie.put(key.as_bytes(), ());
        }
        // Nodes: root, a, b, c.
        assert_eq!(trie.count(b"", nodes(4)), Ok(3));
        assert_eq!(trie.count(b"", nodes(3)), Err(OverBudget));
        assert_eq!(trie.complete(b"", 10, nodes(3)), Err(OverBudget));
        assert_eq!(words(trie.complete(b"", 1, nodes(2))), ["a"]);
    }

    #[test]
    fn complete_charges_copied_bytes() {
        let mut trie = RadixTrie::new();
        let long = vec![b'x'; 1000];
        trie.put(&long, ());
        // One node visit, but 1000 bytes into the buffer and 1000 out.
        assert_eq!(trie.complete(b"", 1, Budget::new(2, 1999)), Err(OverBudget));
        assert_eq!(
            trie.complete(b"", 1, Budget::new(2, 2000)),
            Ok(vec![long.clone()])
        );
        // A prefix ending mid-edge still copies the rest of the edge.
        assert_eq!(
            trie.complete(b"xx", 1, Budget::new(2, 1997)),
            Err(OverBudget)
        );
        assert_eq!(trie.count(b"", Budget::new(2, 0)), Ok(1));
    }

    #[test]
    fn split_and_merge_are_charged_and_atomic() {
        let mut trie = RadixTrie::new();
        let long = vec![b'a'; 1000];
        trie.put(&long, 1);

        // Inserting "ab" splits the 1000-byte edge.
        assert_eq!(trie.insert(b"ab", 2, bytes(999)), Err(OverBudget));
        assert_eq!(trie.labels(), [&b""[..], &long[..]]);
        assert_eq!(trie.get(b"ab"), None);
        assert_eq!(trie.insert(b"ab", 2, bytes(1000)), Ok(()));
        // A new leaf needs no split.
        assert_eq!(trie.insert(b"z", 3, bytes(0)), Ok(()));

        // Deleting "ab" leaves valueless "a" with one child: merge "a" + rest.
        assert_eq!(trie.delete(b"ab", bytes(999)), Err(OverBudget));
        assert_eq!(trie.get(b"ab"), Some(&2));
        trie.check_invariants();
        assert_eq!(trie.delete(b"ab", bytes(1000)), Ok(true));
        assert_eq!(trie.labels(), [&b""[..], &long[..], b"z"]);
        // Deleting a leaf whose parent keeps a value or branches merges nothing.
        assert_eq!(trie.delete(b"z", bytes(0)), Ok(true));
    }

    #[test]
    fn deleting_a_node_with_one_child_charges_the_merge() {
        let mut trie = RadixTrie::new();
        let mut long_key = b"a".to_vec();
        long_key.extend_from_slice(&[b'b'; 999]);
        trie.put(b"a", 1);
        trie.put(&long_key, 2);
        assert_eq!(trie.labels(), [&b""[..], b"a", &long_key[1..]]);

        // "a" keeps one child: deleting it merges "a" + 999 bytes.
        assert_eq!(trie.delete(b"a", bytes(999)), Err(OverBudget));
        assert_eq!(trie.get(b"a"), Some(&1));
        assert_eq!(trie.delete(b"a", bytes(1000)), Ok(true));
        assert_eq!(trie.labels(), [&b""[..], &long_key[..]]);
        trie.check_invariants();
    }

    #[test]
    fn edges_split_and_merge_inside_multibyte_characters() {
        let mut trie = RadixTrie::new();
        trie.put("é".as_bytes(), 1); // C3 A9
        trie.put("è".as_bytes(), 2); // C3 A8
        assert_eq!(trie.labels(), [&b""[..], b"\xC3", b"\xA8", b"\xA9"]);
        assert_eq!(words(trie.complete(b"", 10, UNLIMITED)), ["è", "é"]);
        assert_eq!(words(trie.complete(b"\xC3", 10, UNLIMITED)), ["è", "é"]);
        assert!(trie.del("è".as_bytes()));
        assert_eq!(trie.labels(), [&b""[..], "é".as_bytes()]);
        trie.check_invariants();
    }

    #[test]
    fn deep_chains_do_not_overflow() {
        // 200k nested nodes ("a", "aa", ...), built directly in O(n), then
        // traversed and dropped on a 256 KiB stack: any recursion overflows.
        const DEPTH: usize = 200_000;
        let mut trie = RadixTrie::new();
        let mut node = &mut trie.root;
        for _ in 0..DEPTH {
            node.children.push(Node::new(b"a", Some(())));
            node = &mut node.children[0];
        }
        crate::store::test_support::on_small_stack(move || {
            let mut trie = trie;
            trie.check_invariants();
            assert_eq!(trie.count(b"", UNLIMITED), Ok(DEPTH));
            assert_eq!(words(trie.complete(b"aaa", 1, UNLIMITED)), ["aaa"]);
            assert!(trie.del(&vec![b'a'; DEPTH]));
            assert_eq!(trie.count(b"", UNLIMITED), Ok(DEPTH - 1));
            drop(trie);
        });
    }
}
