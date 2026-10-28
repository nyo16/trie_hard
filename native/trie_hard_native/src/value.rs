use std::sync::Arc;

/// A stored value.
///
/// Values are encoded to external term format by the Elixir side (where
/// `term_to_binary/1` yields on large terms), so the NIF only moves bytes.
#[derive(Clone)]
pub enum Value {
    /// The value is the key itself (`add_word_list/2`); no bytes are stored.
    SelfKey,
    /// External term format bytes. `Arc` lets `get` clone the handle under the
    /// read lock and copy the bytes into a BEAM binary after releasing it.
    Etf(Arc<[u8]>),
}
