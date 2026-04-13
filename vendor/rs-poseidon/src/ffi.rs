use ruint::aliases::U256;

/// Hash 1-4 BN254 field elements using Poseidon.
///
/// Each element is 4 little-endian u64 limbs (256 bits).
/// Result is written to `output` in the same format.
///
/// # Safety
/// - `inputs` must point to `count` consecutive `[u64; 4]` arrays
/// - `output` must point to a writable `[u64; 4]`
/// - `count` must be 1-4
#[no_mangle]
pub unsafe extern "C" fn poseidon_hash(
    inputs: *const [u64; 4],
    count: i32,
    output: *mut u64,
) {
    let count = count as usize;
    assert!((1..=4).contains(&count));

    let input_slice = std::slice::from_raw_parts(inputs, count);
    let u256_inputs: Vec<U256> = input_slice
        .iter()
        .map(|limbs| U256::from_limbs(*limbs))
        .collect();

    let result = crate::poseidon::hash(&u256_inputs);
    let out_limbs = result.as_limbs();

    let out_slice = std::slice::from_raw_parts_mut(output, 4);
    out_slice.copy_from_slice(out_limbs);
}
