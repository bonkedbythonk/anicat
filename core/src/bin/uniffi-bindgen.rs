//! Bindings generator, built as a bin so the generator version can never drift
//! from the `uniffi` version the library itself was compiled against — a skew
//! there produces Swift that links but calls the wrong FFI symbols.
fn main() {
    uniffi::uniffi_bindgen_main()
}
