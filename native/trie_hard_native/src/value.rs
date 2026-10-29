use std::sync::{Arc, LazyLock};

/// A stored value: external term format bytes, encoded by the Elixir side
/// (where `term_to_binary/1` yields on large terms), so the NIF only moves
/// bytes. `Arc` lets `get` clone the handle under the read lock and copy the
/// bytes into a BEAM binary after releasing it.
///
/// Empty bytes mean "the value is the key itself" (`add_word_list/2`): ETF is
/// never empty, and one pointer keeps `Option<Value>` at 16 bytes per node.
#[derive(Clone)]
pub struct Value(Arc<[u8]>);

/// Shared by every self-key value, so `add_word_list/2` allocates nothing.
static SELF_KEY: LazyLock<Arc<[u8]>> = LazyLock::new(|| Arc::from(&[][..]));

impl Value {
    pub fn etf(bytes: &[u8]) -> Self {
        debug_assert!(!bytes.is_empty(), "external term format is never empty");
        Value(Arc::from(bytes))
    }

    pub fn self_key() -> Self {
        Value(Arc::clone(&SELF_KEY))
    }

    /// The ETF bytes, or `None` when the value is the key itself.
    pub fn etf_bytes(&self) -> Option<&[u8]> {
        (!self.0.is_empty()).then_some(&*self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn option_value_is_one_pointer() {
        assert_eq!(std::mem::size_of::<Option<Value>>(), 16);
    }

    #[test]
    fn self_key_and_etf_are_distinguished() {
        assert_eq!(Value::self_key().etf_bytes(), None);
        assert_eq!(
            Value::etf(&[131, 97, 1]).etf_bytes(),
            Some(&[131, 97, 1][..])
        );
    }
}
