//! The one BLAS routine the speech engine calls. Apple's platforms have it
//! in Accelerate; everywhere else this gives it, by the `matrixmultiply`
//! crate, so no native library has to be built or shipped.

// On Apple platforms only the tests call this.
#![cfg_attr(all(target_vendor = "apple", not(test)), allow(dead_code))]

const ROW_MAJOR: i32 = 101;
const NO_TRANSPOSE: i32 = 111;

/// `C = alpha · op(A) · op(B) + beta · C`, as CBLAS's `sgemm` takes it.
///
/// # Safety
/// The pointers must be valid for the matrices the sizes and leading
/// dimensions describe, as for CBLAS.
#[allow(clippy::too_many_arguments)]
pub(crate) unsafe fn sgemm(
    order: i32,
    trans_a: i32,
    trans_b: i32,
    m: i32,
    n: i32,
    k: i32,
    alpha: f32,
    a: *const f32,
    lda: i32,
    b: *const f32,
    ldb: i32,
    beta: f32,
    c: *mut f32,
    ldc: i32,
) {
    let row_major = order == ROW_MAJOR;
    // A matrix stored the other way round is its transpose: both are a
    // choice of which stride walks rows.
    let strides =
        |trans: i32, ld: i32| if (trans == NO_TRANSPOSE) == row_major { (ld as isize, 1) } else { (1, ld as isize) };
    let ((rsa, csa), (rsb, csb)) = (strides(trans_a, lda), strides(trans_b, ldb));
    let (rsc, csc) = strides(NO_TRANSPOSE, ldc);
    // SAFETY: the caller's contract is CBLAS's, which is this routine's.
    unsafe {
        matrixmultiply::sgemm(m as usize, k as usize, n as usize, alpha, a, rsa, csa, b, rsb, csb, beta, c, rsc, csc);
    }
}

/// The symbol the engine links against where there is no Accelerate.
///
/// # Safety
/// As [`sgemm`].
#[cfg(not(target_vendor = "apple"))]
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn cblas_sgemm(
    order: i32,
    trans_a: i32,
    trans_b: i32,
    m: i32,
    n: i32,
    k: i32,
    alpha: f32,
    a: *const f32,
    lda: i32,
    b: *const f32,
    ldb: i32,
    beta: f32,
    c: *mut f32,
    ldc: i32,
) {
    unsafe { sgemm(order, trans_a, trans_b, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A (2×3) and B (3×2), row-major, and their product.
    const A: [f32; 6] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
    const B: [f32; 6] = [7.0, 8.0, 9.0, 10.0, 11.0, 12.0];
    const AB: [f32; 4] = [58.0, 64.0, 139.0, 154.0];

    #[test]
    fn row_major_products_are_right() {
        let mut c = [1.0_f32; 4];
        unsafe {
            sgemm(
                ROW_MAJOR,
                NO_TRANSPOSE,
                NO_TRANSPOSE,
                2,
                2,
                3,
                1.0,
                A.as_ptr(),
                3,
                B.as_ptr(),
                2,
                0.0,
                c.as_mut_ptr(),
                2,
            )
        };
        assert_eq!(c, AB);
        // alpha and beta: 2·AB + 1·C.
        unsafe {
            sgemm(
                ROW_MAJOR,
                NO_TRANSPOSE,
                NO_TRANSPOSE,
                2,
                2,
                3,
                2.0,
                A.as_ptr(),
                3,
                B.as_ptr(),
                2,
                1.0,
                c.as_mut_ptr(),
                2,
            )
        };
        assert_eq!(c, [174.0, 192.0, 417.0, 462.0]);
    }

    #[test]
    fn transposed_operands_are_read_the_other_way() {
        // Bᵀ stored row-major as a 2×3 matrix: transposing it gives B back.
        let b_transposed = [7.0_f32, 9.0, 11.0, 8.0, 10.0, 12.0];
        let mut c = [0.0_f32; 4];
        unsafe {
            sgemm(
                ROW_MAJOR,
                NO_TRANSPOSE,
                112,
                2,
                2,
                3,
                1.0,
                A.as_ptr(),
                3,
                b_transposed.as_ptr(),
                3,
                0.0,
                c.as_mut_ptr(),
                2,
            )
        };
        assert_eq!(c, AB);
    }
}
