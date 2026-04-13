mod constants;

use ark_bn254::Fr;
use ark_ff::{Field, Zero};
use ruint::aliases::U256;

const N_ROUNDS_F: u8 = 8;
const N_ROUNDS_P: [i32; 16] = [
    56, 57, 56, 60, 60, 63, 64, 63, 60, 66, 60, 65, 70, 60, 64, 68,
];

// Add round constants.
fn arc(state: &mut Vec<Fr>, c: &[Fr]) {
    for (i, a) in state.iter_mut().enumerate() {
        *a += c[i];
    }
}

// Sbox function.
fn sbox(state: &mut Vec<Fr>) {
    for a in state.iter_mut() {
        *a = a.pow([5]);
    }
}

// Mix layer.
fn mix(state: &mut Vec<Fr>, m: &[Vec<Fr>]) {
    let mut state_new = vec![Fr::zero(); state.len()];
    for i in 0..state.len() {
        let mut lc = Fr::zero();
        for j in 0..state.len() {
            lc += m[j][i] * state[j];
        }
        state_new[i] = lc;
    }
    *state = state_new;
}

fn full_round(state: &mut Vec<Fr>, c: &[Fr], m: &[Vec<Fr>]) {
    sbox(state);
    arc(state, c);
    mix(state, m);
}

// Compute a Poseidon hash function of the input vector.
//
// # Panics
//
// Panics if `input` is not a valid field element.
#[must_use]
pub fn hash(inputs: &[U256]) -> U256 {
    assert!(!inputs.is_empty());
    assert!(inputs.len() <= N_ROUNDS_P.len());

    let t = inputs.len() + 1;
    let n_rounds_f = N_ROUNDS_F as usize;
    let n_rounds_p = N_ROUNDS_P[t - 2] as usize;
    let c = constants::C_CONST[t - 2].clone();
    let s = constants::S_CONST[t - 2].clone();
    let m = constants::M_CONST[t - 2].clone();
    let p = constants::P_CONST[t - 2].clone();

    let mut state: Vec<Fr> = inputs.iter().map(|f| f.try_into().unwrap()).collect();
    state.insert(0, Fr::zero());

    arc(&mut state, &c[0..t]);
    for r in 0..(n_rounds_f / 2) {
        if r == (n_rounds_f / 2) - 1 {
            full_round(
                &mut state,
                &c[((n_rounds_f / 2) - 1 + 1) * t..((n_rounds_f / 2) - 1 + 2) * t],
                &p,
            );
        } else {
            full_round(&mut state, &c[(r + 1) * t..(r + 2) * t], &m)
        }
    }

    for r in 0..n_rounds_p {
        state[0] = state[0].pow([5]);
        state[0] += c[(n_rounds_f / 2 + 1) * t + r];

        let mut s0 = Fr::zero();
        for i in 0..t {
            s0 += s[(t * 2 - 1) * r + i] * state[i];
        }

        for k in 1..t {
            state[k] = state[k] + state[0] * s[(t * 2 - 1) * r + t + k - 1];
        }
        state[0] = s0;
    }

    for r in 0..(n_rounds_f / 2) - 1 {
        full_round(
            &mut state,
            &c[(n_rounds_f / 2 + 1) * t + n_rounds_p + r * t
                ..(n_rounds_f / 2 + 1) * t + n_rounds_p + (r + 1) * t]
                .to_vec(),
            &m,
        );
    }

    sbox(&mut state);
    mix(&mut state, &m);

    state[0].into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruint::uint;

    #[test]
    fn test_hash_inputs() {
        uint! {
            assert_eq!(hash(&[0_U256]), 0x2a09a9fd93c590c26b91effbb2499f07e8f7aa12e2b4940a3aed2411cb65e11c_U256);
            assert_eq!(hash(&[0_U256, 0_U256]), 0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864_U256);
            assert_eq!(hash(&[1_U256, 2_U256]), 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a_U256);
            assert_eq!(hash(&[1_U256, 2_U256, 3_U256, 4_U256]), 0x299c867db6c1fdd79dcefa40e4510b9837e60ebb1ce0663dbaa525df65250465_U256);
            assert_eq!(hash(&[0_U256, 0_U256, 0_U256]), 0xbc188d27dcceadc1dcfb6af0a7af08fe2864eecec96c5ae7cee6db31ba599aa_U256);
            assert_eq!(hash(&[31213_U256, 132_U256]), 0x303f59cd0831b5633bcda50514521b33776b5d4280eb5868ba1dbbe2e4d76ab5_U256);
        }
    }
}
